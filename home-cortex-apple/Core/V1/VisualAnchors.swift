@preconcurrency import ARKit
import Foundation
import simd

enum VisualAnchorError: LocalizedError {
    case catalog, noAnchor, ambiguous, inconsistent
    var errorDescription: String? {
        switch self {
        case .catalog: "This room has no readable anchor geometry. Refresh its anchors."
        case .noAnchor: "Face a mounted anchor with the rear camera. Move closer until its tags are clear."
        case .ambiguous: "The view is ambiguous. Move slightly sideways while keeping the anchor visible."
        case .inconsistent: "Anchor observations disagree. Check print scale and mounting coordinates, then try again."
        }
    }
}

extension RigidTransform {
    init(rowMajor m: [[Double]]) throws {
        guard m.count == 4, m.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) }) else {
            throw LocalizationFailure.invalidTransform
        }
        try self.init(matrix: simd_float4x4(columns: (
            SIMD4(m[0][0], m[1][0], m[2][0], m[3][0]).float,
            SIMD4(m[0][1], m[1][1], m[2][1], m[3][1]).float,
            SIMD4(m[0][2], m[1][2], m[2][2], m[3][2]).float,
            SIMD4(m[0][3], m[1][3], m[2][3], m[3][3]).float)))
    }
    func point(_ p: SIMD3<Double>) -> SIMD3<Double> { rotation.act(p) + translation }
    static var opticalFromARCamera: RigidTransform {
        // Raw ARFrame pixels: optical right/down/forward; ARKit camera right/up/back.
        try! RigidTransform(rotation: simd_quatd(angle: .pi, axis: SIMD3(1, 0, 0)), translation: .zero)
    }
}
private extension SIMD4 where Scalar == Double {
    var float: SIMD4<Float> { SIMD4<Float>(Float(x), Float(y), Float(z), Float(w)) }
}

struct VisualAnchorCatalog: Decodable, Sendable {
    let space_id: String
    let frame_id: String
    let manifest_sha256: String
    let units: String
    let boards: [Board]
    struct Board: Decodable, Sendable {
        let board_id: String
        let installation_status: String
        let T_world_from_board: [[Double]]
        let fiducials: [Tag]
    }
    struct Tag: Decodable, Sendable {
        let family: String
        let tag_id: Int
        let detection_edge_m: Double
        let T_world_from_apriltag: [[Double]]
        let detection_corners_world_m: [[Double]]
    }
    func geometry(selectedBoards: Set<String>) throws -> [VisualTag] {
        guard units == "meters", space_id.hasPrefix("space:"), !frame_id.isEmpty,
              manifest_sha256.count == 64 else { throw VisualAnchorError.catalog }
        var result: [VisualTag] = []
        var ids = Set<Int>()
        for board in boards where selectedBoards.contains(board.board_id) {
            let boardPose = try RigidTransform(rowMajor: board.T_world_from_board)
            for tag in board.fiducials {
                guard tag.family == "tag36h11", (0..<587).contains(tag.tag_id), ids.insert(tag.tag_id).inserted,
                      tag.detection_edge_m.isFinite, tag.detection_edge_m > 0,
                      tag.detection_corners_world_m.count == 4,
                      tag.detection_corners_world_m.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) else {
                    throw VisualAnchorError.catalog
                }
                result.append(VisualTag(id: tag.tag_id, boardID: board.board_id, edge: tag.detection_edge_m,
                    spaceFromTag: try RigidTransform(rowMajor: tag.T_world_from_apriltag),
                    corners: tag.detection_corners_world_m.map { SIMD3($0[0], $0[1], $0[2]) },
                    boardCenter: boardPose.translation, boardNormal: boardPose.rotation.act(SIMD3(0, 0, 1))))
            }
        }
        guard !result.isEmpty else { throw VisualAnchorError.catalog }
        return result
    }
}
struct VisualTag: Sendable {
    let id: Int
    let boardID: String
    let edge: Double
    let spaceFromTag: RigidTransform
    let corners: [SIMD3<Double>]
    let boardCenter: SIMD3<Double>
    let boardNormal: SIMD3<Double>
}
struct VisualDetection: Sendable {
    let id: Int
    let corners: [SIMD2<Double>]
    let cameraFromTag: RigidTransform
    let alternative: RigidTransform?
}
struct VisualIntrinsics: Sendable {
    let fx: Double, fy: Double, cx: Double, cy: Double
    func project(_ p: SIMD3<Double>) -> SIMD2<Double>? {
        guard p.z > 0.01 else { return nil }
        return SIMD2(fx*p.x/p.z+cx, fy*p.y/p.z+cy)
    }
}
struct VisualSolution: Sendable {
    let spaceFromOpticalCamera: RigidTransform
    let boardIDs: [String]
    let tagCount: Int
    let rmse: Double
    var disagreements: [VisualAnchorDisagreement] = []
}
struct VisualAnchorDisagreement: Sendable {
    let boardID: String
    let distanceMeters: Double
    let angleRadians: Double
}

/// Joint 6-DOF reprojection fit: one tag can seed a pose; every accepted corner
/// on every visible board constrains the same pose. No Euler averaging or LLM.
enum VisualPoseSolver {
    private struct Match { let tag: VisualTag; let detection: VisualDetection }
    static func solve(tags: [VisualTag], detections: [VisualDetection], intrinsics k: VisualIntrinsics,
                      checkingBoardConsistency: Bool = true) throws -> VisualSolution {
        guard [k.fx, k.fy, k.cx, k.cy].allSatisfy(\.isFinite), k.fx > 0, k.fy > 0 else { throw VisualAnchorError.catalog }
        guard Set(tags.map(\.id)).count == tags.count,
              tags.allSatisfy({ $0.corners.count == 4 }) else { throw VisualAnchorError.catalog }
        let catalog = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) })
        // Reject duplicate IDs in a frame: their physical identity is ambiguous.
        let counts = Dictionary(grouping: detections, by: \.id)
        let matches = detections.compactMap { d -> Match? in
            guard counts[d.id]?.count == 1, let tag = catalog[d.id], d.corners.count == 4,
                  d.corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  (0..<4).allSatisfy({ simd_distance(d.corners[$0], d.corners[($0+1)%4]) >= 8 }) else { return nil }
            return Match(tag: tag, detection: d)
        }
        guard !matches.isEmpty else { throw VisualAnchorError.noAnchor }
        var seeds: [(RigidTransform, [Match], Double)] = []
        for m in matches.prefix(32) {
            for cameraFromTag in [m.detection.cameraFromTag, m.detection.alternative].compactMap({ $0 }) {
                let seed = try cameraFromTag.composed(with: m.tag.spaceFromTag.inverse)
                let accepted = matches.filter { rms(seed, [$0], k) < 8 }
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
            let inliers = matches.filter { rms(fitted, [$0], k) < 4 }
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
                let boardTags = tags.filter { $0.boardID == boardID }
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
        for m in matches {
            for i in 0..<4 {
                guard let p = k.project(t.point(m.tag.corners[i])) else { return nil }
                let r = p - m.detection.corners[i]; values += [r.x, r.y]
            }
        }
        return values
    }
    private static func rms(_ t: RigidTransform, _ m: [Match], _ k: VisualIntrinsics) -> Double {
        guard let r = residuals(t, m, k) else { return .infinity }
        return sqrt(r.reduce(0) { $0 + $1*$1 } / Double(m.count*4))
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

struct VisualFrame: Sendable {
    let pixels: Data
    let width: Int, height: Int, stride: Int
    let intrinsics: VisualIntrinsics
    let worldFromARCamera: RigidTransform
    let worldID: String
    let measuredAt: Date
}

/// C detector and nonlinear solve stay off the main actor; raw pixels are copied
/// once and bounded to a single in-flight frame by the localization worker.
private final class AprilTagHandle: @unchecked Sendable {
    let pointer = hc_detector_create()
    deinit { hc_detector_destroy(pointer) }
}
actor VisualAnchorDetector {
    // The handle's lifetime is Sendable; its mutable C state is actor-confined.
    private let detector = AprilTagHandle()
    func detections(frame: VisualFrame, tags: [VisualTag]) throws -> [VisualDetection] {
        var sizes = [Double](repeating: 0, count: 587)
        for tag in tags { sizes[tag.id] = tag.edge }
        var output = [HCDetection](repeating: HCDetection(), count: 128)
        let k = frame.intrinsics
        let count = frame.pixels.withUnsafeBytes { bytes in
            sizes.withUnsafeBufferPointer { sizes in
                hc_detect(detector.pointer, bytes.bindMemory(to: UInt8.self).baseAddress,
                    Int32(frame.width), Int32(frame.height), Int32(frame.stride),
                    k.fx, k.fy, k.cx, k.cy, sizes.baseAddress, sizes.count, &output, 128)
            }
        }
        return try output.prefix(Int(count)).map { raw -> VisualDetection in
            let corners = withUnsafeBytes(of: raw.corners) { Array($0.bindMemory(to: Double.self)) }
            func transform<T>(_ value: T) throws -> RigidTransform {
                let a = withUnsafeBytes(of: value) { Array($0.bindMemory(to: Double.self)) }
                return try RigidTransform(rowMajor: (0..<4).map { Array(a[($0*4)..<($0*4+4)]) })
            }
            return VisualDetection(id: Int(raw.tag_id), corners: (0..<4).map { SIMD2(corners[2*$0], corners[2*$0+1]) },
                cameraFromTag: try transform(raw.camera_from_tag),
                alternative: raw.has_alternative == 1 ? try transform(raw.alternative_camera_from_tag) : nil)
        }
    }
    func solve(frame: VisualFrame, tags: [VisualTag]) throws -> VisualSolution {
        try VisualPoseSolver.solve(tags: tags, detections: detections(frame: frame, tags: tags), intrinsics: frame.intrinsics)
    }
}
