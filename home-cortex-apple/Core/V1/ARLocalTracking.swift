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
    @ObservationIgnored private var previewing = false
    @ObservationIgnored private var sampling = false
    @ObservationIgnored private var copying = false
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
        session.delegate = self
        worldID = "tracking:" + UUID().uuidString.lowercased()
        wallOrigin = Date(); uptimeOrigin = ProcessInfo.processInfo.systemUptime
        running = true; state = .initializing; reason = "Initializing visual-inertial tracking"
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }
    func stop() {
        cancelCapture()
        generation += 1; session.pause(); running = false; cameraPose = nil; measuredAt = nil
        Task { await encoder.clear() }
        worldID = nil; sequence = 0; lastTimestamp = -.infinity; state = .unavailable; reason = "Localization is off"
    }
    func cancelCapture() { captureID = UUID() }
    func measurementTime(_ timestamp: Double) -> Date? {
        let now = ProcessInfo.processInfo.systemUptime
        guard timestamp.isFinite, timestamp <= now + 0.01, now - timestamp < 0.5 else { return nil }
        let date = wallOrigin.addingTimeInterval(timestamp - uptimeOrigin)
        guard abs(Date().timeIntervalSince(wallOrigin) - (now - uptimeOrigin)) < 0.5 else { return nil }
        return date
    }
    @discardableResult func poll() -> Bool {
        guard running else { return false }
        guard let frame = session.currentFrame else { cameraPose = nil; measuredAt = nil; state = .lost; return false }
        guard frame.timestamp > lastTimestamp, let time = measurementTime(frame.timestamp),
              let pose = try? RigidTransform(matrix: frame.camera.transform) else {
            if measuredAt.map({ Date().timeIntervalSince($0) > 0.5 }) ?? false { cameraPose = nil; measuredAt = nil; state = .lost; reason = "Tracking sample unavailable or clock discontinuity" }
            return false
        }
        lastTimestamp = frame.timestamp; sequence += 1
        cameraPose = nil; measuredAt = nil
        switch frame.camera.trackingState {
        case .normal: cameraPose = pose; measuredAt = time; state = .unanchored; reason = "Local camera pose only; household calibration unavailable"
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
    func visualFrame() async throws -> VisualFrame {
        guard !copying else { throw VisionFailure.busy }
        copying = true; defer { copying = false }
        guard running, state == .unanchored, let worldID, let frame = session.currentFrame,
              case .normal = frame.camera.trackingState, let time = measurementTime(frame.timestamp) else {
            throw CalibrationError.tracking
        }
        let token = generation
        let result = try await encoder.visual(ARPixels(buffer: frame.capturedImage), camera: frame.camera, world: worldID, time: time)
        try Task.checkCancellation()
        guard token == generation else { throw CalibrationError.tracking }
        return result
    }
    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in self.stop(); self.state = .relocalizationRequired; self.reason = "Camera/session interrupted; recalibration required" }
    }
    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in if self.state == .relocalizationRequired { self.start(resetReason: "Camera interruption ended; new unanchored world") } }
    }
    nonisolated func session(_ session: ARSession, didFailWithError error: any Error) {
        Task { @MainActor in self.stop(); self.reason = "ARKit session failed" }
    }
    nonisolated static func opticalPose(_ arPose: RigidTransform) throws -> RigidTransform {
        try arPose.composed(with: .opticalFromARCamera)
    }
    func diagnostic(body: String) -> JSONValue? {
        guard state == .unanchored, let worldID, let measuredAt, let cameraPose, let optical = try? Self.opticalPose(cameraPose), Date().timeIntervalSince(measuredAt) < 0.3 else { return nil }
        return .object(["embodiment_id": .string(body), "world_id": .string(worldID), "source": .string("ARKit"),
                        "reference_frame": .string("session_local_y_up"), "pose_frame": .string("camera_optical"),
                        "household_aligned": .bool(false), "uncertainty": .string("unknown"),
                        "tracking_state": .string(state.rawValue), "tracking_reason": .string(reason),
                        "reset_reason": .string(resetReason),
                        "publication_blocker": .string(publicationBlocker), "measured_at": .string(V1Time.format(measuredAt)),
                        "sequence": .integer(sequence), "camera_pose": optical.diagnostic])
    }
    func freshImage(deadline: Date) async throws -> CapturedImage {
        let interval = PerformanceInterval("FreshEvidenceCapture")
        defer { interval.end() }
        guard running else { throw VisionFailure.unavailable }
        guard !capturing else { throw VisionFailure.busy }
        capturing = true; defer { capturing = false }
        let token = generation, requested = Date(), id = UUID()
        let limit = min(deadline, requested.addingTimeInterval(5))
        captureID = id
        // Wait for a new exposure from the existing AR session; snapshots never reset its world.
        while running, token == generation, captureID == id, Date() < limit,
              session.currentFrame.flatMap({ measurementTime($0.timestamp) }).map({ $0 >= requested }) != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard captureID == id else { throw CancellationError() }
        guard let frame = session.currentFrame else { throw VisionFailure.unavailable }
        try Task.checkCancellation()
        guard running, token == generation else { throw VisionFailure.staleSession }
        guard let time = measurementTime(frame.timestamp), time >= requested, Date() < limit else { throw VisionFailure.timeout }
        let encodingStart = Date()
        let image = try await encoder.encode(ARPixels(buffer: frame.capturedImage), capturedAt: time, maxSide: 1280, limit: VisualEvidence.maxMediaBytes)
        try Task.checkCancellation()
        guard token == generation, captureID == id, Date() < deadline else { throw VisionFailure.timeout }
        return CapturedImage(jpeg: image.jpeg, capturedAt: time, cameraID: "camera:rear-primary", width: image.width, height: image.height,
                             captureDuration: encodingStart.timeIntervalSince(requested), encodingDuration: Date().timeIntervalSince(encodingStart))
    }
    func observationFrame(body: String) async throws -> ObservationFrame {
        guard !sampling else { throw VisionFailure.busy }
        sampling = true; defer { sampling = false }
        guard !capturing, running, let frame = session.currentFrame,
              let time = measurementTime(frame.timestamp) else { throw VisionFailure.unavailable }
        let token = generation, world = worldID
        // The diagnostic and upright image describe exactly this ARFrame, not the latest poll.
        var diagnostic: JSONValue?
        if case .normal = frame.camera.trackingState, let worldID,
           let pose = try? Self.opticalPose(RigidTransform(matrix: frame.camera.transform)) {
            diagnostic = .object(["embodiment_id": .string(body), "world_id": .string(worldID), "source": .string("ARKit"),
                "reference_frame": .string("session_local_y_up"), "pose_frame": .string("camera_optical"),
                "household_aligned": .bool(false), "uncertainty": .string("unknown"),
                "tracking_state": .string(LocalizationState.unanchored.rawValue), "tracking_reason": .string(String(describing: frame.camera.trackingState)),
                "reset_reason": .string(resetReason), "publication_blocker": .string(publicationBlocker),
                "measured_at": .string(V1Time.format(time)), "sequence": .integer(max(1,sequence)), "camera_pose": pose.diagnostic])
        }
        let image = try await encoder.render(ARPixels(buffer: frame.capturedImage),capturedAt: time,maxSide: 960)
        try Task.checkCancellation()
        guard token == generation else { throw VisionFailure.staleSession }
        return ObservationFrame(image: image,capturedAt: time,diagnostic: diagnostic,coordinateWorld: world)
    }
    func previewImage() async throws -> InspectionImage {
        guard !capturing, !previewing else { throw VisionFailure.busy }
        guard running, let frame = session.currentFrame, let time = measurementTime(frame.timestamp) else { throw VisionFailure.unavailable }
        previewing = true; defer { previewing = false }
        let token = generation
        let image = try await encoder.encode(ARPixels(buffer: frame.capturedImage), capturedAt: time, maxSide: 640, limit: 98_304)
        try Task.checkCancellation()
        guard token == generation else { throw VisionFailure.staleSession }
        return image
    }
    func previewDisplayImage() async throws -> DisplayPreview {
        guard !capturing, !previewing else { throw VisionFailure.busy }
        guard running, let frame = session.currentFrame, let time = measurementTime(frame.timestamp) else { throw VisionFailure.unavailable }
        previewing = true; defer { previewing = false }
        let token = generation
        let image = try await encoder.render(ARPixels(buffer: frame.capturedImage), capturedAt: time,maxSide: 640)
        try Task.checkCancellation()
        guard token == generation else { throw VisionFailure.staleSession }
        return DisplayPreview(image: image, capturedAt: time)
    }
}

struct DisplayPreview: @unchecked Sendable {
    // Immutable CGImage; mutable camera buffers never cross into UI state.
    let image: CGImage
    let capturedAt: Date
}

private struct ARPixels: @unchecked Sendable {
    // Retain exactly one pixel buffer across the serial encoder actor call.
    let buffer: CVPixelBuffer
}
private actor ARImageEncoder {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var previewTime: Date?
    private var previewImage: CGImage?
    private var previewJPEG: InspectionImage?
    func clear() { previewTime = nil; previewImage = nil; previewJPEG = nil }

    func visual(_ sample: ARPixels, camera: ARCamera, world: String, time: Date) throws -> VisualFrame {
        try Task.checkCancellation()
        let pixels = sample.buffer
        let interval = PerformanceInterval("FrameCopy")
        defer { interval.end() }
        guard CVPixelBufferGetPlaneCount(pixels) >= 1 else { throw CalibrationError.tracking }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(pixels, 0), height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0), width > 0, height > 0,
              width <= 8192, height <= 8192, stride >= width else { throw CalibrationError.tracking }
        let k = camera.intrinsics
        return VisualFrame(pixels: Data(bytes: base, count: stride*height), width: width, height: height, stride: stride,
            intrinsics: VisualIntrinsics(fx: Double(k.columns.0.x), fy: Double(k.columns.1.y),
                cx: Double(k.columns.2.x), cy: Double(k.columns.2.y)),
            worldFromARCamera: try RigidTransform(matrix: camera.transform), worldID: world, measuredAt: time)
    }

    func render(_ pixels: ARPixels, capturedAt: Date, maxSide: Double) throws -> CGImage {
        try Task.checkCancellation()
        if maxSide == 640, previewTime == capturedAt, let previewImage { return previewImage }
        let source = CIImage(cvPixelBuffer: pixels.buffer).oriented(.right)
        let factor = min(1, maxSide / max(source.extent.width, source.extent.height))
        let image = source.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        guard let cg = context.createCGImage(image, from: image.extent.integral) else { throw VisionFailure.internalError }
        if maxSide == 640 { previewTime = capturedAt; previewImage = cg; previewJPEG = nil }
        return cg
    }
    func encode(_ pixels: ARPixels, capturedAt: Date, maxSide: Double, limit: Int) throws -> InspectionImage {
        let interval = PerformanceInterval("ARImageEncode")
        defer { interval.end() }
        if maxSide == 640, previewTime == capturedAt, let previewJPEG, previewJPEG.jpeg.count <= limit { return previewJPEG }
        let cg = try render(pixels, capturedAt: capturedAt, maxSide: maxSide)
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { throw VisionFailure.internalError }
        CGImageDestinationAddImage(destination, cg, [kCGImageDestinationLossyCompressionQuality: maxSide > 640 ? 0.75 : 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(destination), jpeg.length <= limit else { throw VisionFailure.invalidArgument }
        let result = InspectionImage(jpeg: jpeg as Data, capturedAt: capturedAt, width: cg.width, height: cg.height)
        if maxSide == 640 { previewJPEG = result }
        return result
    }
}
