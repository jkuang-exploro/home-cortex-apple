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
    init(rowMajor m: UnsafeBufferPointer<Double>) throws {
        guard m.count == 16, m.allSatisfy(\.isFinite) else { throw LocalizationFailure.invalidTransform }
        try self.init(matrix: simd_float4x4(columns: (
            SIMD4(m[0], m[4], m[8], m[12]).float,
            SIMD4(m[1], m[5], m[9], m[13]).float,
            SIMD4(m[2], m[6], m[10], m[14]).float,
            SIMD4(m[3], m[7], m[11], m[15]).float)))
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
struct VisualTag: Equatable, Sendable {
    let id: Int
    let boardID: String
    let edge: Double
    let spaceFromTag: RigidTransform
    let corners: [SIMD3<Double>]
    let boardCenter: SIMD3<Double>
    let boardNormal: SIMD3<Double>
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.boardID == rhs.boardID && lhs.edge == rhs.edge &&
        lhs.spaceFromTag.rotation.vector == rhs.spaceFromTag.rotation.vector &&
        lhs.spaceFromTag.translation == rhs.spaceFromTag.translation && lhs.corners == rhs.corners &&
        lhs.boardCenter == rhs.boardCenter && lhs.boardNormal == rhs.boardNormal
    }
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
