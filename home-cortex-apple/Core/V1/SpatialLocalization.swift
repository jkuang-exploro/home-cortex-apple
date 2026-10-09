import Foundation
import simd

enum LocalizationFailure: Error { case invalidTransform, missingExtrinsic, unavailableReference, invalidUncertainty }

/// Active, column-vector SI transform. A camera origin is never a body origin.
struct RigidTransform: Sendable {
    let rotation: simd_quatd
    let translation: SIMD3<Double>
    init(rotation: simd_quatd, translation: SIMD3<Double>) throws {
        guard rotation.vector.x.isFinite, rotation.vector.y.isFinite, rotation.vector.z.isFinite,
              rotation.vector.w.isFinite, abs(simd_length(rotation.vector) - 1) < 1e-5,
              translation.x.isFinite, translation.y.isFinite, translation.z.isFinite else { throw LocalizationFailure.invalidTransform }
        self.rotation = simd_normalize(rotation); self.translation = translation
    }
    init(matrix: simd_float4x4) throws {
        let r = simd_double3x3(columns: (SIMD3<Double>(Double(matrix.columns.0.x), Double(matrix.columns.0.y), Double(matrix.columns.0.z)),
                                       SIMD3<Double>(Double(matrix.columns.1.x), Double(matrix.columns.1.y), Double(matrix.columns.1.z)),
                                       SIMD3<Double>(Double(matrix.columns.2.x), Double(matrix.columns.2.y), Double(matrix.columns.2.z))))
        guard abs(simd_determinant(r) - 1) < 1e-4,
              simd_length(r.columns.0) > 0,
              (0..<3).allSatisfy({ i in (0..<3).allSatisfy { j in abs(simd_dot(r[i], r[j]) - (i == j ? 1 : 0)) < 1e-4 } }),
              abs(matrix.columns.0.w) < 1e-6, abs(matrix.columns.1.w) < 1e-6,
              abs(matrix.columns.2.w) < 1e-6, abs(matrix.columns.3.w - 1) < 1e-6 else { throw LocalizationFailure.invalidTransform }
        try self.init(rotation: simd_quatd(r), translation: SIMD3(Double(matrix.columns.3.x), Double(matrix.columns.3.y), Double(matrix.columns.3.z)))
    }
    var inverse: RigidTransform {
        get throws { try RigidTransform(rotation: rotation.inverse, translation: rotation.inverse.act(-translation)) }
    }
    func composed(with child: RigidTransform) throws -> RigidTransform {
        try RigidTransform(rotation: simd_normalize(rotation * child.rotation), translation: translation + rotation.act(child.translation))
    }
    var diagnostic: JSONValue { .object([
        "position_m": .array([translation.x, translation.y, translation.z].map(JSONValue.number)),
        "quaternion": .array(IPhoneBodyFrame.components(rotation).map(JSONValue.number))]) }
}

enum LocalizationState: String, Sendable {
    case unavailable = "UNAVAILABLE", initializing = "INITIALIZING", unanchored = "TRACKING_UNANCHORED"
    case calibrating = "CALIBRATING", anchored = "TRACKING_ANCHORED", limited = "LIMITED", lost = "LOST"
    case relocalizationRequired = "RELOCALIZATION_REQUIRED"
}

struct HouseholdAlignment: Sendable {
    let worldID: String
    let deviceSession: String
    let spaceID: String
    let referenceID: String
    let revision: Int
    let spaceFromWorld: RigidTransform
    init(worldID: String, deviceSession: String, spaceID: String, referenceID: String, revision: Int,
         referenceBodyInSpace: RigidTransform, referenceCameraInWorld: RigidTransform, bodyFromCamera: RigidTransform?) throws {
        guard let bodyFromCamera else { throw LocalizationFailure.missingExtrinsic }
        guard spaceID.hasPrefix("space:"), !worldID.isEmpty, !deviceSession.isEmpty, !referenceID.isEmpty, revision > 0 else { throw LocalizationFailure.unavailableReference }
        self.worldID = worldID; self.deviceSession = deviceSession; self.spaceID = spaceID; self.referenceID = referenceID; self.revision = revision
        let worldFromBody = try referenceCameraInWorld.composed(with: bodyFromCamera.inverse)
        spaceFromWorld = try referenceBodyInSpace.composed(with: worldFromBody.inverse)
    }
    func bodyPose(cameraInWorld: RigidTransform, bodyFromCamera: RigidTransform) throws -> RigidTransform {
        try spaceFromWorld.composed(with: cameraInWorld).composed(with: bodyFromCamera.inverse)
    }
}

/// No default p95 and no production approval implied by creating this value.
struct PoseUncertaintyEnvelope: Sendable {
    let approvedRevision: String
    let p95: [Double]
    let maxSeconds: Double
    let maxPathMeters: Double
    let maxRadiusMeters: Double
    let maxAbsPitch: Double
    init(approvedRevision: String, p95: [Double], maxSeconds: Double, maxPathMeters: Double, maxRadiusMeters: Double, maxAbsPitch: Double) throws {
        guard !approvedRevision.isEmpty, p95.count == 6, p95.allSatisfy({ $0.isFinite && $0 >= 0 }),
              [maxSeconds, maxPathMeters, maxRadiusMeters, maxAbsPitch].allSatisfy({ $0.isFinite && $0 > 0 }), maxAbsPitch < .pi / 2 else { throw LocalizationFailure.invalidUncertainty }
        self.approvedRevision = approvedRevision; self.p95 = p95; self.maxSeconds = maxSeconds
        self.maxPathMeters = maxPathMeters; self.maxRadiusMeters = maxRadiusMeters; self.maxAbsPitch = maxAbsPitch
    }
    func permits(seconds: Double, path: Double, radius: Double, pitch: Double) -> Bool {
        [seconds, path, radius, pitch].allSatisfy(\.isFinite) && seconds >= 0 && seconds <= maxSeconds && path >= 0 && path <= maxPathMeters && radius >= 0 && radius <= maxRadiusMeters && abs(pitch) <= maxAbsPitch
    }
}

enum CanonicalPoseEncoding {
    static func value(body: String, space: String, measuredAt: Date, pose: RigidTransform, uncertainty: PoseUncertaintyEnvelope) -> JSONValue {
        let a = IPhoneBodyFrame.euler(pose.rotation)
        let values = [pose.translation.x, pose.translation.y, pose.translation.z, a.x, a.y, a.z]
        let names = ["x", "y", "z", "yaw", "pitch", "roll"]
        let transform = Dictionary(uniqueKeysWithValues: zip(names.indices, names).map { i, name in
            (name, JSONValue.object(["value": .number(values[i]), "p95": .number(uncertainty.p95[i])])) })
        return .object(["embodiment_id": .string(body), "space_id": .string(space), "measured_at": .string(V1Time.format(measuredAt)),
                        "validity": .string("valid"), "transform": .object(transform)])
    }
}
