@preconcurrency import ARKit
import Foundation
import Observation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// The only AR camera owner. Local camera pose remains diagnostic while extrinsics are unknown.
@MainActor @Observable final class ARLocalTracking: NSObject, ARSessionDelegate {
    private(set) var state = LocalizationState.unavailable
    private(set) var reason = "Localization is off"
    private(set) var worldID: String?
    private(set) var measuredAt: Date?
    private(set) var cameraPose: RigidTransform?
    private(set) var sequence: Int64 = 0
    private(set) var running = false
    private(set) var resetReason = "Localization is off"
    @ObservationIgnored private let session = ARSession()
    @ObservationIgnored private var lastTimestamp = -Double.infinity
    @ObservationIgnored private var wallOrigin = Date()
    @ObservationIgnored private var uptimeOrigin = 0.0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var capturing = false
    @ObservationIgnored private var captureContinuation: CheckedContinuation<ARFrame, any Error>?
    @ObservationIgnored private var captureID = UUID()
    @ObservationIgnored private let encoder = ARImageEncoder()
    var supported: Bool { ARWorldTrackingConfiguration.isSupported }
    var debugStatus: String {
        let frame = session.currentFrame
        return "running=\(running) state=\(state.rawValue) reason=\(reason) sequence=\(sequence) frame_timestamp=\(frame?.timestamp ?? -1) uptime=\(ProcessInfo.processInfo.systemUptime) camera_tracking=\(String(describing: frame?.camera.trackingState))"
    }
    var publicationBlocker: String { "Measured camera/body extrinsic and validated uncertainty profile required" }
    func start(resetReason: String = "New tracking session; household alignment not restored") {
        stop()
        self.resetReason = resetReason
        guard supported else { reason = "ARKit world tracking unavailable"; return }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing { config.videoFormat = format }
        session.delegate = self
        worldID = "tracking:" + UUID().uuidString.lowercased()
        wallOrigin = Date(); uptimeOrigin = ProcessInfo.processInfo.systemUptime
        running = true; state = .initializing; reason = "Initializing visual-inertial tracking"
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }
    func stop() {
        cancelCapture()
        generation += 1; session.pause(); running = false; cameraPose = nil; measuredAt = nil
        worldID = nil; sequence = 0; lastTimestamp = -.infinity; state = .unavailable; reason = "Localization is off"
    }
    func cancelCapture() {
        captureID = UUID(); let pending = captureContinuation; captureContinuation = nil
        pending?.resume(throwing: CancellationError())
    }
    private func highResolutionFrame(deadline: Date) async throws -> ARFrame {
        let id = UUID(); captureID = id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                captureContinuation = continuation
                session.captureHighResolutionFrame { frame, error in
                    Task { @MainActor in
                        guard self.captureID == id, let pending = self.captureContinuation else { return }
                        self.captureContinuation = nil
                        if let frame { pending.resume(returning: frame) }
                        else { pending.resume(throwing: error ?? VisionFailure.unavailable) }
                    }
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                    guard self.captureID == id, let pending = self.captureContinuation else { return }
                    self.captureContinuation = nil; self.captureID = UUID()
                    pending.resume(throwing: VisionFailure.timeout)
                }
            }
        } onCancel: { Task { @MainActor in if self.captureID == id { self.cancelCapture() } } }
    }
    func measurementTime(_ timestamp: Double) -> Date? {
        let now = ProcessInfo.processInfo.systemUptime
        guard timestamp.isFinite, timestamp <= now + 0.01, now - timestamp < 0.5 else { return nil }
        let date = wallOrigin.addingTimeInterval(timestamp - uptimeOrigin)
        guard abs(Date().timeIntervalSince(wallOrigin) - (now - uptimeOrigin)) < 0.5 else { return nil }
        return date
    }
    @discardableResult func poll() -> Bool {
        guard running, let frame = session.currentFrame else { return false }
        guard frame.timestamp > lastTimestamp, let time = measurementTime(frame.timestamp),
              let pose = try? RigidTransform(matrix: frame.camera.transform) else {
            if measuredAt.map({ Date().timeIntervalSince($0) > 0.5 }) ?? false { cameraPose = nil; measuredAt = nil; state = .lost; reason = "Tracking sample unavailable or clock discontinuity" }
            return false
        }
        lastTimestamp = frame.timestamp; measuredAt = time; sequence += 1; cameraPose = pose
        switch frame.camera.trackingState {
        case .normal: state = .unanchored; reason = "Local camera pose only; household calibration unavailable"
        case .notAvailable: state = .lost; reason = "ARKit tracking unavailable"
        case .limited(let cause):
            state = .limited
            switch cause {
            case .initializing: reason = "Initializing"
            case .excessiveMotion: reason = "Excessive motion"
            case .insufficientFeatures: reason = "Insufficient visual features"
            case .relocalizing: reason = "Relocalization required"
            @unknown default: reason = "Limited tracking"
            }
        }
        return true
    }
    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in self.cameraPose = nil; self.measuredAt = nil; self.state = .relocalizationRequired; self.reason = "Camera/session interrupted; recalibration required" }
    }
    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in if self.running { self.start(resetReason: "Camera interruption ended; new unanchored world") } }
    }
    nonisolated func session(_ session: ARSession, didFailWithError error: any Error) {
        Task { @MainActor in self.stop(); self.reason = "ARKit session failed" }
    }
    func diagnostic(body: String) -> JSONValue? {
        guard let worldID, let measuredAt, let cameraPose, Date().timeIntervalSince(measuredAt) < 0.3 else { return nil }
        return .object(["embodiment_id": .string(body), "world_id": .string(worldID), "source": .string("ARKit"),
                        "reference_frame": .string("session_local_y_up"), "pose_frame": .string("camera_optical"),
                        "household_aligned": .bool(false), "uncertainty": .string("unknown"),
                        "tracking_state": .string(state.rawValue), "tracking_reason": .string(reason),
                        "reset_reason": .string(resetReason),
                        "publication_blocker": .string(publicationBlocker), "measured_at": .string(V1Time.format(measuredAt)),
                        "sequence": .integer(sequence), "camera_pose": cameraPose.diagnostic])
    }
    func freshImage(deadline: Date) async throws -> CapturedImage {
        guard running else { throw VisionFailure.unavailable }
        guard !capturing else { throw VisionFailure.busy }
        capturing = true; defer { capturing = false }
        let token = generation, requested = Date()
        // Callback is deadline-bounded by the caller task; stale/out-of-order completions cannot be evidence.
        let frame = try await highResolutionFrame(deadline: min(deadline, Date().addingTimeInterval(5)))
        try Task.checkCancellation()
        guard running, token == generation else { throw VisionFailure.staleSession }
        guard let time = measurementTime(frame.timestamp), time >= requested, Date() < deadline else { throw VisionFailure.timeout }
        let encodingStart = Date()
        let image = try await encoder.encode(ARPixels(frame.capturedImage), capturedAt: time, maxSide: 1280, limit: VisualEvidence.maxMediaBytes)
        guard token == generation, Date() < deadline else { throw VisionFailure.timeout }
        return CapturedImage(jpeg: image.jpeg, capturedAt: time, cameraID: "camera:rear-primary", width: image.width, height: image.height,
                             captureDuration: encodingStart.timeIntervalSince(requested), encodingDuration: Date().timeIntervalSince(encodingStart))
    }
    func previewImage() async throws -> InspectionImage {
        guard running, let frame = session.currentFrame, let time = measurementTime(frame.timestamp) else { throw VisionFailure.unavailable }
        let token = generation
        let image = try await encoder.encode(ARPixels(frame.capturedImage), capturedAt: time, maxSide: 640, limit: 98_304)
        guard token == generation else { throw VisionFailure.staleSession }
        return image
    }
}

private struct ARPixels: @unchecked Sendable {
    // Retain exactly one pixel buffer across the serial encoder actor call.
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}
private actor ARImageEncoder {
    private let context = CIContext(options: [.cacheIntermediates: false])
    func encode(_ pixels: ARPixels, capturedAt: Date, maxSide: Double, limit: Int) throws -> InspectionImage {
        let source = CIImage(cvPixelBuffer: pixels.buffer).oriented(.right)
        let factor = min(1, maxSide / max(source.extent.width, source.extent.height))
        let image = source.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        guard let cg = context.createCGImage(image, from: image.extent.integral) else { throw VisionFailure.internalError }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { throw VisionFailure.internalError }
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: maxSide > 640 ? 0.75 : 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(destination), jpeg.length <= limit else { throw VisionFailure.invalidArgument }
        return InspectionImage(jpeg: jpeg as Data, capturedAt: capturedAt, width: cg.width, height: cg.height)
    }
}
