import Foundation

struct LocalizationReferenceCatalog: Decodable, Sendable {
    let spaces: [LocalizationSpaceOption]
    let person_id: String
}
struct LocalizationSpaceOption: Decodable, Identifiable, Sendable {
    let space_id: String
    let name: JSONValue?
    let coordinate_ready: Bool
    let references: [LocalizationReferenceOption]
    let can_manage: Bool
    let frame_definition: JSONValue?
    var anchor_boards: VisualAnchorCatalog? = nil
    var id: String { space_id }
    var displayName: String {
        if case .string(let text) = name { return text }
        if case .object(let names) = name {
            if case .string(let text) = names["en"] { return text }
            for key in names.keys.sorted() {
                if case .string(let text) = names[key] { return text }
            }
        }
        return space_id
    }
}
struct ReferenceVector: Codable, Equatable, Sendable {
    var x: Double; var y: Double; var z: Double
}
struct ReferenceAngles: Codable, Equatable, Sendable {
    var yaw: Double; var pitch: Double; var roll: Double
}
struct ReferencePose: Codable, Equatable, Sendable {
    var position: ReferenceVector
    var orientation: ReferenceAngles
    var transform: RigidTransform {
        get throws {
            try RigidTransform(rotation: IPhoneBodyFrame.quaternion(yaw: orientation.yaw, pitch: orientation.pitch, roll: orientation.roll),
                translation: SIMD3(position.x, position.y, position.z))
        }
    }
    static let identity = ReferencePose(position: .init(x:0,y:0,z:0), orientation: .init(yaw:0,pitch:0,roll:0))
}
struct ReferenceProvenance: Codable, Equatable, Sendable {
    let person_id: String; let surveyed_at: String; let method: String
}
struct PendingReferenceSave: Codable, Sendable {
    let spaceID: String
    let reference: LocalizationReferenceOption
    let expectedRevision: Int
    let frameDefinition: JSONValue?
}
struct LocalizationReferenceOption: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let type: String
    let position: ReferenceVector
    let orientation: ReferenceAngles
    let reference: Metadata
    var displayName: String { reference.display_name ?? id }
    var bodyInSpace: RigidTransform {
        get throws {
            try ReferencePose(position: position, orientation: orientation).transform.composed(with: reference.body_in_reference.transform)
        }
    }
    struct Metadata: Codable, Equatable, Sendable {
        let revision: Int
        let reference_frame: String
        let coordinate_convention: String
        let body_frame: String
        let body_in_reference: ReferencePose
        let placement_instructions: String
        let measurement_notes: String
        let provenance: ReferenceProvenance
        let status: String
        let display_name: String?
    }
}

