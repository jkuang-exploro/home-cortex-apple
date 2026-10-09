import Foundation
import Observation
import simd

enum CalibrationState: String, Sendable {
  case notConfigured = "NOT_CONFIGURED"
  case referenceAvailable = "REFERENCE_AVAILABLE"
  case initializing = "INITIALIZING"
  case waitingForReference = "WAITING_FOR_REFERENCE"
  case capturing = "CAPTURING"
  case validating = "VALIDATING"
  case anchored = "ANCHORED_PROVISIONAL"
  case provisional = "REFERENCE_PROVISIONAL"
  case degraded = "DEGRADED"
  case relocalizationRequired = "RELOCALIZATION_REQUIRED"
  case failed = "FAILED"
}
struct CalibrationObservation: Sendable {
  let worldID: String
  let deviceSession: String
  let measuredAt: Date
  let cameraPose: RigidTransform
  let healthy: Bool
  var screenDownAndFlat: Bool { cameraPose.rotation.act(SIMD3(0, 0, -1)).y > cos(5 * .pi / 180) }
}
struct CalibrationCandidate: Sendable {
  let reference: LocalizationReferenceOption
  let spaceID: String
  let worldID: String
  let deviceSession: String
  let measuredAt: Date
  let alignment: HouseholdAlignment?
  let translationSpread: Double
  let rotationSpread: Double
}
enum CalibrationError: LocalizedError {
  case tracking, moved, reset, reference, insufficientSamples, geometry
  var errorDescription: String? {
    switch self {
    case .tracking:
      "Tracking is not ready. Use a well-lit area with visible detail, and leave the rear camera uncovered."
    case .moved:
      "The phone moved or was not flat and screen-down. Lay it flat at the reference and try again."
    case .reset: "Tracking restarted or the DEVICE connection changed. Capture the reference again."
    case .reference:
      "The reference does not describe this phone's full placement. Choose a compatible reference."
    case .insufficientSamples: "There are not enough fresh, steady observations. Try again."
    case .geometry:
      "Measured camera/body geometry is unavailable. The reference can be saved provisionally; household alignment cannot be activated."
    }
  }
}

/// Pure observation validation. The stability thresholds are repeatability checks, never p95 claims.
enum CalibrationValidation {
  static func candidate(
    reference: LocalizationReferenceOption, spaceID: String, observations: [CalibrationObservation],
    bodyFromCamera: RigidTransform?, now: Date
  ) throws -> CalibrationCandidate {
    guard reference.reference.body_frame == "iphone.body.v1",
      reference.reference.coordinate_convention == "right_handed_zyx_z_up_si_v1"
    else { throw CalibrationError.reference }
    guard observations.count >= 15, let first = observations.first, let last = observations.last,
      last.measuredAt.timeIntervalSince(first.measuredAt) >= 1,
      now.timeIntervalSince(last.measuredAt) >= 0, now.timeIntervalSince(last.measuredAt) < 0.5
    else { throw CalibrationError.insufficientSamples }
    var translation = 0.0
    var rotation = 0.0
    for (index, sample) in observations.enumerated() {
      guard sample.worldID == first.worldID, sample.deviceSession == first.deviceSession else {
        throw CalibrationError.reset
      }
      guard sample.healthy else { throw CalibrationError.tracking }
      guard sample.screenDownAndFlat else { throw CalibrationError.moved }
      if index > 0, sample.measuredAt <= observations[index - 1].measuredAt {
        throw CalibrationError.insufficientSamples
      }
      translation = max(
        translation, simd_length(sample.cameraPose.translation - first.cameraPose.translation))
      rotation = max(
        rotation,
        2
          * acos(
            min(
              1, abs(simd_dot(sample.cameraPose.rotation.vector, first.cameraPose.rotation.vector)))
          ))
    }
    guard translation <= 0.02, rotation <= 2 * .pi / 180 else { throw CalibrationError.moved }
    let referencePose = try reference.bodyInSpace
    let alignment: HouseholdAlignment?
    if let bodyFromCamera {
      alignment = try HouseholdAlignment(
        worldID: first.worldID, deviceSession: first.deviceSession, spaceID: spaceID,
        referenceID: reference.id, revision: reference.reference.revision,
        referenceBodyInSpace: referencePose,
        referenceCameraInWorld: last.cameraPose, bodyFromCamera: bodyFromCamera)
    } else {
      alignment = nil
    }
    return CalibrationCandidate(
      reference: reference, spaceID: spaceID, worldID: last.worldID,
      deviceSession: last.deviceSession,
      measuredAt: last.measuredAt, alignment: alignment, translationSpread: translation,
      rotationSpread: rotation)
  }
}

@MainActor @Observable final class SpatialCalibrationSession {
  private(set) var state = CalibrationState.notConfigured
  private(set) var reference: LocalizationReferenceOption?
  private(set) var spaceID: String?
  private(set) var calibratedAt: Date?
  private(set) var alignment: HouseholdAlignment?
  private(set) var bodyPose: RigidTransform?
  private(set) var message = "Choose a household reference."
  private(set) var translationSpread: Double?
  private(set) var rotationSpread: Double?
  @ObservationIgnored private var extrinsic: RigidTransform?

  func activate(
    _ candidate: CalibrationCandidate, currentWorld: String?, currentSession: String?,
    bodyFromCamera: RigidTransform?
  ) throws {
    guard candidate.worldID == currentWorld, candidate.deviceSession == currentSession else {
      throw CalibrationError.reset
    }
    reference = candidate.reference
    spaceID = candidate.spaceID
    calibratedAt = candidate.measuredAt
    translationSpread = candidate.translationSpread
    rotationSpread = candidate.rotationSpread
    alignment = candidate.alignment
    extrinsic = bodyFromCamera
    bodyPose = nil
    if alignment != nil && bodyFromCamera != nil {
      state = .anchored
      message = "Household alignment is provisional. Spatial accuracy is not yet validated."
    } else {
      state = .provisional
      message = CalibrationError.geometry.localizedDescription
    }
  }
  func referenceSaved(_ reference: LocalizationReferenceOption, spaceID: String) {
    if self.reference == reference, self.spaceID == spaceID { return }
    self.reference = reference
    self.spaceID = spaceID
    alignment = nil
    bodyPose = nil
    calibratedAt = nil
    extrinsic = nil
    state = .referenceAvailable
    message = "Reference saved. Return to its fixed placement to relocalize."
  }
  func invalidate(_ reason: String) {
    alignment = nil
    bodyPose = nil
    extrinsic = nil
    if reference != nil {
      state = .relocalizationRequired
      message = reason
    }
  }
  func update(
    worldID: String?, deviceSession: String?, cameraPose: RigidTransform?, trackingHealthy: Bool,
    measuredAt: Date?, now: Date = Date()
  ) {
    guard let alignment else { return }
    guard worldID == alignment.worldID, deviceSession == alignment.deviceSession else {
      invalidate("Tracking restarted. Return to the saved reference to relocalize.")
      return
    }
    guard trackingHealthy, let measuredAt, now.timeIntervalSince(measuredAt) >= 0,
      now.timeIntervalSince(measuredAt) < 0.5,
      let cameraPose, let extrinsic
    else {
      invalidate("Tracking was interrupted. Relocalization is required.")
      return
    }
    bodyPose = try? alignment.bodyPose(cameraInWorld: cameraPose, bodyFromCamera: extrinsic)
    if bodyPose == nil { invalidate("The household transform is invalid. Relocalize again.") }
  }
  var diagnostic: JSONValue? {
    guard let reference, let spaceID else { return nil }
    var fields: [String: JSONValue] = [
      "state": .string(state.rawValue), "space_id": .string(spaceID),
      "reference_id": .string(reference.id),
      "reference_revision": .integer(Int64(reference.reference.revision)),
      "accuracy_validated": .bool(false), "reason": .string(message),
    ]
    fields["calibrated_at"] = calibratedAt.map { .string(V1Time.format($0)) } ?? .null
    fields["household_body_pose"] = bodyPose?.diagnostic ?? .null
    fields["translation_spread_m"] = translationSpread.map(JSONValue.number) ?? .null
    fields["rotation_spread_rad"] = rotationSpread.map(JSONValue.number) ?? .null
    return .object(fields)
  }
}
