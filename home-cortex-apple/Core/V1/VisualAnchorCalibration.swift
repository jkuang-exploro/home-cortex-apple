import Foundation
import Observation
import simd

struct VisualAlignmentSample: Sendable {
    let spaceFromWorld: RigidTransform
    let measuredAt: Date
    let boardIDs: [String]
    let tagCount: Int
    let rmse: Double
    init(solution: VisualSolution, frame: VisualFrame) throws {
        // T_room_from_world = T_room_from_optical * T_optical_from_AR * inverse(T_world_from_AR).
        spaceFromWorld = try solution.spaceFromOpticalCamera
            .composed(with: .opticalFromARCamera).composed(with: frame.worldFromARCamera.inverse)
        measuredAt = frame.measuredAt; boardIDs = solution.boardIDs
        tagCount = solution.tagCount; rmse = solution.rmse
    }
}
struct VisualCalibrationConflict: Identifiable, Sendable {
    let id = UUID()
    let previousBoardIDs: [String]
    let proposedBoardIDs: [String]
    let distanceMeters: Double
    let angleRadians: Double
    var choices: [String] { Array(Set(previousBoardIDs + proposedBoardIDs)).sorted() }
    var description: String {
        "\(previousBoardIDs.joined(separator: ", ")) and \(proposedBoardIDs.joined(separator: ", ")) disagree by " +
        String(format: "%.2f m / %.1f°. ", distanceMeters, angleRadians*180 / .pi) +
        "Keep the current calibration, or erase it and choose an anchor to start again. Saved anchor coordinates will remain unchanged."
    }
}
private struct VisualConflictObservation {
    let sample: VisualAlignmentSample
    let previous: [String]
    let proposed: [String]
    let distance: Double
    let angle: Double
    let simultaneous: Bool
}

@MainActor @Observable final class VisualAnchorCalibration {
    private(set) var catalog: VisualAnchorCatalog?
    private(set) var tags: [VisualTag] = []
    private(set) var cameraPose: RigidTransform?
    private(set) var spaceFromWorld: RigidTransform?
    private(set) var worldID: String?
    private(set) var deviceSession: String?
    private(set) var calibratedAt: Date?
    private(set) var boardIDs: [String] = []
    private(set) var tagCount = 0
    private(set) var reprojectionRMSE: Double?
    private(set) var translationSpread: Double?
    private(set) var rotationSpread: Double?
    private(set) var enabled = false
    private(set) var message = "Face a mounted anchor to calibrate this room."
    private(set) var generation = 0
    private(set) var completedBoardIDs: [String] = []
    private(set) var completionNotice: String?
    private(set) var completionSequence = 0
    private(set) var pendingConflict: VisualCalibrationConflict?
    private(set) var ignoredBoardIDs: [String] = []
    @ObservationIgnored private var samples: [VisualAlignmentSample] = []
    @ObservationIgnored private var conflictObservations: [VisualConflictObservation] = []
    var aligned: Bool { spaceFromWorld != nil }
    var needsVisualObservations: Bool { enabled && pendingConflict == nil && !tags.isEmpty }
    var activeBoardIDs: [String] { Array(Set(tags.map(\.boardID))).sorted() }
    func begin(catalog: VisualAnchorCatalog, selectedBoards: Set<String>, deviceSession: String) throws {
        let tags = try catalog.geometry(selectedBoards: selectedBoards)
        invalidate("Face a selected anchor with the rear camera. Keep its tags in view.")
        self.catalog = catalog; self.tags = tags; self.deviceSession = deviceSession
        enabled = true
    }
    func invalidate(_ reason: String) {
        generation += 1; enabled = false; samples = []
        spaceFromWorld = nil; cameraPose = nil; worldID = nil; calibratedAt = nil
        boardIDs = []; tagCount = 0; reprojectionRMSE = nil
        completedBoardIDs = []; completionNotice = nil; pendingConflict = nil
        ignoredBoardIDs = []; conflictObservations = []
        translationSpread = nil; rotationSpread = nil; message = reason
    }
    func receive(solution: VisualSolution, frame: VisualFrame, session: String, now: Date = Date()) throws {
        guard pendingConflict == nil else { return }
        guard enabled, session == deviceSession, now.timeIntervalSince(frame.measuredAt) >= 0,
              now.timeIntervalSince(frame.measuredAt) < 1 else { throw CalibrationError.reset }
        if let worldID, worldID != frame.worldID {
            invalidate("Tracking restarted. Face an anchor and calibrate again.")
            throw CalibrationError.reset
        }
        worldID = frame.worldID
        let next = try VisualAlignmentSample(solution: solution, frame: frame)
        guard samples.last.map({ next.measuredAt > $0.measuredAt }) ?? true else { return }
        samples = samples.filter { next.measuredAt.timeIntervalSince($0.measuredAt) < 8 }
        let previousIDs = completedBoardIDs.isEmpty ? samples.last?.boardIDs ?? solution.boardIDs : completedBoardIDs
        if !solution.disagreements.isEmpty {
            let all = Set(solution.boardIDs + solution.disagreements.map(\.boardID))
            // Canonical ordering before the first alignment prevents two equally
            // supported boards alternating as the fitter's winner from hiding a conflict.
            let prior = aligned ? previousIDs : [all.sorted().first!]
            let proposed = all.subtracting(prior)
            recordConflict(next, previous: prior, proposed: Array(proposed.isEmpty ? all : proposed).sorted(),
                distance: solution.disagreements.map(\.distanceMeters).max() ?? 0,
                angle: solution.disagreements.map(\.angleRadians).max() ?? 0, simultaneous: true)
            return
        }
        // Compare against the durable session alignment even after the short
        // observation window has expired. An unseen new board cannot replace it.
        if let previous = spaceFromWorld ?? samples.last?.spaceFromWorld {
            let distance = simd_distance(next.spaceFromWorld.translation, previous.translation)
            let angle = 2*acos(min(1, abs(simd_dot(next.spaceFromWorld.rotation.vector, previous.rotation.vector))))
            if distance > 0.15 || angle > 12 * .pi/180 {
                recordConflict(next, previous: previousIDs, proposed: next.boardIDs, distance: distance, angle: angle)
                return
            }
        }
        conflictObservations = []
        samples.append(next)
        if samples.count > 16 { samples.removeFirst(samples.count-16) }
        boardIDs = Array(Set(samples.flatMap(\.boardIDs))).sorted()
        tagCount = next.tagCount; reprojectionRMSE = next.rmse
        guard samples.count >= 3, let first = samples.first,
              next.measuredAt.timeIntervalSince(first.measuredAt) >= 0.4 else {
            message = "Anchor detected. Keep it visible while the room alignment settles."
            return
        }
        let reference = first.spaceFromWorld.rotation.vector
        var q = SIMD4<Double>.zero, p = SIMD3<Double>.zero, total = 0.0
        for sample in samples {
            // Reprojection residual weights fits, not a claimed confidence/p95.
            let weight = 1/max(0.25, sample.rmse*sample.rmse)
            var v = sample.spaceFromWorld.rotation.vector
            if simd_dot(v, reference) < 0 { v = -v }
            q += v*weight; p += sample.spaceFromWorld.translation*weight; total += weight
        }
        let alignment = try RigidTransform(rotation: simd_quatd(vector: simd_normalize(q)), translation: p/total)
        translationSpread = samples.map { simd_distance($0.spaceFromWorld.translation, alignment.translation) }.max()
        rotationSpread = samples.map { 2*acos(min(1, abs(simd_dot($0.spaceFromWorld.rotation.vector, alignment.rotation.vector)))) }.max()
        spaceFromWorld = alignment; calibratedAt = next.measuredAt
        var finished: [String] = []
        for id in next.boardIDs where !completedBoardIDs.contains(id) {
            let observations = samples.filter { $0.boardIDs.contains(id) }
            if observations.count >= 3, let first = observations.first, let last = observations.last,
               last.measuredAt.timeIntervalSince(first.measuredAt) >= 0.4 { finished.append(id) }
        }
        if !finished.isEmpty {
            completedBoardIDs = Array(Set(completedBoardIDs + finished)).sorted()
            completionNotice = "Calibration finished: " + finished.sorted().joined(separator: ", ")
            completionSequence += 1
        }
        message = "Room aligned from \(boardIDs.count) anchor\(boardIDs.count == 1 ? "" : "s"). Additional visible anchors refine the pose."
        try updateCamera(frame.worldFromARCamera)
    }
    private func recordConflict(_ sample: VisualAlignmentSample, previous: [String], proposed: [String], distance: Double, angle: Double, simultaneous: Bool = false) {
        conflictObservations = conflictObservations.filter { sample.measuredAt.timeIntervalSince($0.sample.measuredAt) < 2 }
        if let last = conflictObservations.last {
            guard sample.measuredAt > last.sample.measuredAt else { return }
            let change = simd_distance(sample.spaceFromWorld.translation, last.sample.spaceFromWorld.translation)
            let turn = 2*acos(min(1, abs(simd_dot(sample.spaceFromWorld.rotation.vector, last.sample.spaceFromWorld.rotation.vector))))
            if last.previous != previous || last.proposed != proposed || last.simultaneous != simultaneous ||
               (!simultaneous && (change > 0.1 || turn > 8 * .pi/180)) {
                conflictObservations = []
            }
        }
        conflictObservations.append(VisualConflictObservation(sample: sample, previous: previous, proposed: proposed, distance: distance, angle: angle, simultaneous: simultaneous))
        message = "Anchors disagree. Checking repeated observations before changing calibration."
        guard conflictObservations.count >= 3, let first = conflictObservations.first,
              sample.measuredAt.timeIntervalSince(first.sample.measuredAt) >= 0.4 else { return }
        pendingConflict = VisualCalibrationConflict(previousBoardIDs: previous, proposedBoardIDs: proposed,
            distanceMeters: conflictObservations.map(\.distance).max() ?? distance,
            angleRadians: conflictObservations.map(\.angle).max() ?? angle)
        generation += 1
        message = "Anchors disagree. Choose whether to keep or erase the previous calibration."
    }
    func keepCurrentCalibration() {
        guard aligned, let conflict = pendingConflict else { return }
        // Suppress the rejected board for this session, so keeping the previous
        // result does not immediately reopen the same prompt every frame.
        ignoredBoardIDs = Array(Set(ignoredBoardIDs + conflict.proposedBoardIDs)).sorted()
        tags = tags.filter { !ignoredBoardIDs.contains($0.boardID) }
        pendingConflict = nil; conflictObservations = []; generation += 1
        message = "Previous calibration kept. Skipping " + ignoredBoardIDs.joined(separator: ", ") + " until recalibration."
    }
    func eraseAndRecalibrate(using boardID: String) throws {
        guard let conflict = pendingConflict, conflict.choices.contains(boardID),
              let catalog, let deviceSession else { throw VisualAnchorError.catalog }
        // Validate the replacement before erasing anything. begin fences old
        // in-flight detections and clears all prior completions/alignment.
        try begin(catalog: catalog, selectedBoards: [boardID], deviceSession: deviceSession)
        message = "Previous calibration erased. Face " + boardID + " to calibrate again."
    }
    func detectionFailed(_ error: any Error) {
        // A board leaving the image is expected: ARKit carries the alignment.
        if !aligned { message = error.localizedDescription }
    }
    func update(worldID: String?, session: String?, camera: RigidTransform?, healthy: Bool, measuredAt: Date?) {
        guard enabled else { return }
        if session != deviceSession || (self.worldID != nil && worldID != self.worldID) {
            invalidate("Tracking or the connection restarted. Face an anchor to recalibrate.")
            return
        }
        guard healthy, let camera, let measuredAt,
              Date().timeIntervalSince(measuredAt) >= 0, Date().timeIntervalSince(measuredAt) < 0.5 else {
            if aligned { invalidate("Tracking was interrupted. Face an anchor to recalibrate.") }
            return
        }
        try? updateCamera(camera)
    }
    private func updateCamera(_ camera: RigidTransform) throws {
        guard let spaceFromWorld else { return }
        cameraPose = try spaceFromWorld.composed(with: camera).composed(with: .opticalFromARCamera)
    }
    var diagnostic: JSONValue? {
        guard let catalog else { return nil }
        return .object([
            "state": .string(aligned ? "ANCHORED_PROVISIONAL" : enabled ? "CAPTURING" : "RELOCALIZATION_REQUIRED"),
            "space_id": .string(catalog.space_id), "reference_id": .string("visual_anchors"),
            "reference_revision": .integer(1), "reference_kind": .string("visual_anchor"),
            "anchor_manifest_sha256": .string(catalog.manifest_sha256), "anchor_frame_id": .string(catalog.frame_id),
            "accuracy_validated": .bool(false), "reason": .string(message),
            "calibrated_at": calibratedAt.map { .string(V1Time.format($0)) } ?? .null,
            "household_camera_pose": cameraPose?.diagnostic ?? .null,
            "board_ids": .array(boardIDs.map(JSONValue.string)), "tag_count": tagCount > 0 ? .integer(Int64(tagCount)) : .null,
            "reprojection_rmse_px": reprojectionRMSE.map(JSONValue.number) ?? .null,
            "translation_spread_m": translationSpread.map(JSONValue.number) ?? .null,
            "rotation_spread_rad": rotationSpread.map(JSONValue.number) ?? .null,
        ])
    }
}
