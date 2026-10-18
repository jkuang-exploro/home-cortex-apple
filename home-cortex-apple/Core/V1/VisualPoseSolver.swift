import Foundation
import simd

/// Joint 6-DOF reprojection fit: one tag can seed a pose; every accepted corner
/// on every visible board constrains the same pose. No Euler averaging or LLM.
enum VisualPoseSolver {
    private struct Match { let tag: VisualTag; let detection: VisualDetection }
    struct PreparedCatalog {
        let byID: [Int: VisualTag]
        let tagFromSpace: [Int: RigidTransform]
        let byBoard: [String: [VisualTag]]
        init(tags: [VisualTag]) throws {
            guard Set(tags.map(\.id)).count == tags.count,
                  tags.allSatisfy({ $0.corners.count == 4 }) else { throw VisualAnchorError.catalog }
            byID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
            tagFromSpace = try Dictionary(uniqueKeysWithValues: tags.map { ($0.id, try $0.spaceFromTag.inverse) })
            byBoard = Dictionary(grouping: tags, by: \.boardID)
        }
    }
    static func solve(tags: [VisualTag], detections: [VisualDetection], intrinsics: VisualIntrinsics,
                      checkingBoardConsistency: Bool = true) throws -> VisualSolution {
        try solve(catalog: PreparedCatalog(tags: tags), detections: detections,
                  intrinsics: intrinsics, checkingBoardConsistency: checkingBoardConsistency)
    }
    static func solve(catalog: PreparedCatalog, detections: [VisualDetection], intrinsics k: VisualIntrinsics,
                      checkingBoardConsistency: Bool = true) throws -> VisualSolution {
        let interval = PerformanceInterval("PoseSolve")
        defer { interval.end() }
        guard [k.fx, k.fy, k.cx, k.cy].allSatisfy(\.isFinite), k.fx > 0, k.fy > 0 else { throw VisualAnchorError.catalog }
        // Reject duplicate IDs in a frame: their physical identity is ambiguous.
        let counts = Dictionary(grouping: detections, by: \.id)
        let matches = detections.compactMap { d -> Match? in
            guard counts[d.id]?.count == 1, let tag = catalog.byID[d.id], d.corners.count == 4,
                  d.corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  (0..<4).allSatisfy({ simd_distance(d.corners[$0], d.corners[($0+1)%4]) >= 8 }) else { return nil }
            return Match(tag: tag, detection: d)
        }
        guard !matches.isEmpty else { throw VisualAnchorError.noAnchor }
        var seeds: [(RigidTransform, [Match], Double)] = []
        for m in matches.prefix(32) {
            for cameraFromTag in [m.detection.cameraFromTag, m.detection.alternative].compactMap({ $0 }) {
                let seed = try cameraFromTag.composed(with: catalog.tagFromSpace[m.tag.id]!)
                let accepted = matches.filter { rms(seed, match: $0, k) < 8 }
                guard !accepted.isEmpty else { continue }
                seeds.append((seed, accepted, rms(seed, accepted, k)))
            }
        }
        // Consensus first, residual second. A single misread/misplaced board
        // must not pull an otherwise consistent room solution away.
        seeds.sort { $0.1.count == $1.1.count ? $0.2 < $1.2 : $0.1.count > $1.1.count }
        var fits: [(RigidTransform, [Match], Double)] = []
        for (seed, initial, _) in seeds.prefix(8) {
            let fitted = try refine(seed, initial, k)
            let inliers = matches.filter { rms(fitted, match: $0, k) < 4 }
            guard !inliers.isEmpty else { continue }
            let final = try refine(fitted, inliers, k)
            let camera = try final.inverse
            guard inliers.allSatisfy({ simd_dot(camera.translation - $0.tag.boardCenter, $0.tag.boardNormal) > 0.01 }) else { continue }
            fits.append((final, inliers, rms(final, inliers, k)))
        }
        fits.sort { $0.1.count == $1.1.count ? $0.2 < $1.2 : $0.1.count > $1.1.count }
        guard let best = fits.first, best.2 < 3 else { throw VisualAnchorError.inconsistent }
        // Don't advertise an arbitrary planar-pose branch as a measured pose.
        if let rival = fits.dropFirst().first(where: {
            Set($0.1.map { $0.tag.id }) == Set(best.1.map { $0.tag.id }) &&
            $0.1.count == best.1.count && $0.2 < best.2 + 0.15 &&
            abs(simd_dot($0.0.rotation.vector, best.0.rotation.vector)) < cos(10 * .pi/180)
        }), rival.2.isFinite { throw VisualAnchorError.ambiguous }
        let camera = try best.0.inverse
        let usedBoards = Set(best.1.map { $0.tag.boardID })
        var disagreements: [VisualAnchorDisagreement] = []
        if checkingBoardConsistency {
            // A coherent excluded board is different from a noisy corner. Solve
            // it independently so robust outlier rejection cannot hide a conflict.
            let acceptedIDs = Set(best.1.map { $0.tag.id })
            let rejectedBoards = Set(matches.filter { !acceptedIDs.contains($0.tag.id) }.map { $0.tag.boardID })
            for boardID in rejectedBoards.sorted() {
                let boardTags = catalog.byBoard[boardID] ?? []
                let ids = Set(boardTags.map(\.id))
                guard let other = try? solve(tags: boardTags, detections: detections.filter { ids.contains($0.id) },
                    intrinsics: k, checkingBoardConsistency: false) else { continue }
                let distance = simd_distance(camera.translation, other.spaceFromOpticalCamera.translation)
                let angle = 2*acos(min(1, abs(simd_dot(camera.rotation.vector, other.spaceFromOpticalCamera.rotation.vector))))
                if distance > 0.15 || angle > 12 * .pi/180 {
                    disagreements.append(VisualAnchorDisagreement(boardID: boardID, distanceMeters: distance, angleRadians: angle))
                }
            }
        }
        return VisualSolution(spaceFromOpticalCamera: camera,
            boardIDs: Array(usedBoards).sorted(), tagCount: best.1.count, rmse: best.2, disagreements: disagreements)
    }
    private static func residuals(_ t: RigidTransform, _ matches: [Match], _ k: VisualIntrinsics) -> [Double]? {
        var values: [Double] = []
        values.reserveCapacity(matches.count * 8)
        for m in matches {
            for i in 0..<4 {
                guard let p = k.project(t.point(m.tag.corners[i])) else { return nil }
                let r = p - m.detection.corners[i]
                values.append(r.x); values.append(r.y)
            }
        }
        return values
    }
    private static func squaredResidual(_ t: RigidTransform, _ match: Match, _ k: VisualIntrinsics) -> Double {
        var sum = 0.0
        for i in 0..<4 {
            guard let point = k.project(t.point(match.tag.corners[i])) else { return .infinity }
            let r = point - match.detection.corners[i]
            sum += r.x * r.x
            sum += r.y * r.y
        }
        return sum
    }
    private static func rms(_ t: RigidTransform, match: Match, _ k: VisualIntrinsics) -> Double {
        sqrt(squaredResidual(t, match, k) / 4)
    }
    private static func rms(_ t: RigidTransform, _ matches: [Match], _ k: VisualIntrinsics) -> Double {
        // Preserve residual order, without constructing arrays solely to score a pose.
        var sum = 0.0
        for match in matches {
            for i in 0..<4 {
                guard let point = k.project(t.point(match.tag.corners[i])) else { return .infinity }
                let r = point - match.detection.corners[i]
                sum += r.x * r.x
                sum += r.y * r.y
            }
        }
        return sqrt(sum / Double(matches.count * 4))
    }
    private static func perturb(_ t: RigidTransform, _ delta: [Double]) throws -> RigidTransform {
        let v = SIMD3(delta[3], delta[4], delta[5]), angle = simd_length(v)
        let q = angle < 1e-14 ? simd_quatd() : simd_quatd(angle: angle, axis: v/angle)
        return try RigidTransform(rotation: simd_normalize(q*t.rotation), translation: t.translation + SIMD3(delta[0], delta[1], delta[2]))
    }
    private static func refine(_ initial: RigidTransform, _ m: [Match], _ k: VisualIntrinsics) throws -> RigidTransform {
        var t = initial, damping = 1e-3
        for _ in 0..<25 {
            guard let r = residuals(t, m, k) else { break }
            var columns: [[Double]] = []
            for j in 0..<6 {
                var d = [Double](repeating: 0, count: 6); d[j] = 1e-6
                guard let shifted = residuals(try perturb(t, d), m, k) else { return t }
                columns.append(zip(shifted, r).map { ($0-$1)/1e-6 })
            }
            var a = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
            var b = [Double](repeating: 0, count: 6)
            for i in r.indices {
                let w = min(1, 3/max(abs(r[i]), 1e-9))
                for j in 0..<6 {
                    b[j] -= w*columns[j][i]*r[i]
                    for l in 0..<6 { a[j][l] += w*columns[j][i]*columns[l][i] }
                }
            }
            for j in 0..<6 { a[j][j] += damping*max(a[j][j], 1) }
            guard let step = linearSolve(a, b), step.allSatisfy(\.isFinite) else { break }
            let next = try perturb(t, step)
            if rms(next, m, k) < rms(t, m, k) { t = next; damping = max(1e-8, damping/3) }
            else { damping *= 10 }
            if sqrt(step.reduce(0) { $0+$1*$1 }) < 1e-8 { break }
        }
        return t
    }
    private static func linearSolve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        var a = matrix.enumerated().map { $0.element + [rhs[$0.offset]] }
        for j in 0..<6 {
            let pivot = (j..<6).max { abs(a[$0][j]) < abs(a[$1][j]) }!
            guard abs(a[pivot][j]) > 1e-12 else { return nil }
            a.swapAt(j, pivot)
            let scale = a[j][j]
            for k in j...6 { a[j][k] /= scale }
            for i in 0..<6 where i != j {
                let factor = a[i][j]
                for k in j...6 { a[i][k] -= factor*a[j][k] }
            }
        }
        return a.map { $0[6] }
    }
}

