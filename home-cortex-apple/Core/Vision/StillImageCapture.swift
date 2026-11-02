import Foundation
@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import CoreMedia

@MainActor protocol StillImageCapture: AnyObject {
    var availability: VisionFailure? { get }
    var permissionLabel: String { get }
    func requestPermission() async
    func captureFreshImage(deadline: Date) async throws -> CapturedImage
    func cancel()
}
struct InspectionImage: Sendable {
    let jpeg: Data
    let capturedAt: Date
    let width: Int
    let height: Int
}
@MainActor protocol InspectionCamera: AnyObject {
    func startPreview(fps: Int, deliver: @escaping @Sendable (InspectionImage) -> Void) async throws
    func stopPreview()
}

/// One camera session. Canonical photo exposures never reuse inspection samples.
@MainActor final class NativeStillImageCapture: StillImageCapture, InspectionCamera, ObservationAcquiring {
    let tracking = ARLocalTracking()
    private let engine = CameraEngine()
    private var trackingDesired = false
    private var ownershipGeneration = 0
    private var arPreview: Task<Void, Never>?
    private var arPreviewFPS = 3
    private var arPreviewDelivery: (@Sendable (InspectionImage) -> Void)?
    private var photographing = false
    static func permissionFailure(_ status: AVAuthorizationStatus) -> VisionFailure? {
        switch status {
        case .authorized: nil
        case .notDetermined: .unavailable
        case .denied, .restricted: .permissionDenied
        @unknown default: .unavailable
        }
    }
    var availability: VisionFailure? {
        if let error = Self.permissionFailure(AVCaptureDevice.authorizationStatus(for: .video)) { return error }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) == nil ? .unavailable : nil
    }
    var permissionLabel: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: "Not requested"
        case .authorized: "Allowed"
        case .denied: "Denied"
        case .restricted: "Restricted"
        @unknown default: "Unavailable"
        }
    }
    func requestPermission() async {
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
    }
    func captureFreshImage(deadline: Date) async throws -> CapturedImage {
        if let availability { throw availability }
        guard !photographing else { throw VisionFailure.busy }
        photographing = true
        defer { photographing = false }
        if trackingDesired { return try await tracking.freshImage(deadline: deadline) }
        let image = try await engine.photo(deadline: deadline)
        try Task.checkCancellation(); return image
    }
    func beginObservationAcquisition() async throws {
        if let availability { throw availability }
        if !trackingDesired { try await engine.beginObservationAcquisition() }
    }
    func endObservationAcquisition() { engine.endObservationAcquisition() }
    var observationWorld: String? { trackingDesired ? tracking.worldID : nil }
    func observationFrame(body: String) async throws -> ObservationFrame {
        if let availability { throw availability }
        if trackingDesired { return try await tracking.observationFrame(body: body) }
        // One-shot sample of the existing video output; inspection sinks are never replaced.
        return try await engine.sample()
    }
    func cancel() { tracking.cancelCapture() }
    func useTracking(_ enabled: Bool) async {
        ownershipGeneration += 1
        let token = ownershipGeneration
        trackingDesired = enabled
        if !enabled { tracking.stop(); arPreview?.cancel(); arPreview = nil; arPreviewDelivery = nil; return }
        guard availability == nil else { tracking.stop(); return }
        await engine.releaseCamera()
        guard token == ownershipGeneration, trackingDesired else { return }
        tracking.start()
    }
    func stopTracking() {
        ownershipGeneration += 1; trackingDesired = false; tracking.stop(); arPreview?.cancel(); arPreview = nil; arPreviewDelivery = nil
    }
    func startPreview(fps: Int, deliver: @escaping @Sendable (InspectionImage) -> Void) async throws {
        if let availability { throw availability }
        if trackingDesired {
            arPreviewFPS = max(1, min(5, fps))
            arPreviewDelivery = deliver
            guard arPreview == nil else { return }
            arPreview = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, trackingDesired else { return }
                    if let image = try? await tracking.previewImage(), !Task.isCancelled { arPreviewDelivery?(image) }
                    do { try await Task.sleep(for: .milliseconds(1000 / arPreviewFPS)) } catch { return }
                }
            }
            return
        }
        try await engine.preview(fps: fps, deliver: deliver)
    }
    func stopPreview() { arPreview?.cancel(); arPreview = nil; arPreviewDelivery = nil; engine.stopPreview() }
}

/// Mutable AVFoundation state and encoding run on one bounded, serial camera queue.
private final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "HomeCortex.Camera", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var sampleContinuation: CheckedContinuation<ObservationFrame, any Error>?
    private var sampleID = UUID()
    private var observationDemand = false
    private var configured = false
    private var notBefore = Date.distantPast
    private var sampleSide = 960.0
    private var previewSink: (@Sendable (InspectionImage) -> Void)?
    private var previewInterval = 1.0 / 3
    private var lastPreview = Date.distantPast
    private func configure() throws {
        if !configured {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw VisionFailure.unavailable }
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720
            guard session.canAddInput(input), session.canAddOutput(videoOutput) else {
                session.commitConfiguration(); throw VisionFailure.unavailable
            }
            session.addInput(input); session.addOutput(videoOutput)
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.setSampleBufferDelegate(self, queue: queue)
            if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            session.commitConfiguration()
            // Limit sensor delivery when supported; sample/JPEG publication has its own stricter cap.
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 5 && $0.maxFrameRate >= 5 }) {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 5)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 5)
                device.unlockForConfiguration()
            }
            configured = true
        }
        if !session.isRunning { session.startRunning() }
        guard session.isRunning, !session.isInterrupted else { throw VisionFailure.unavailable }
    }
    func beginObservationAcquisition() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,any Error>) in
            queue.async {
                do { try self.configure(); self.observationDemand = true; continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func endObservationAcquisition() { queue.async { self.observationDemand = false; self.stopIfIdle() } }
    func sample(deadline: Date = Date().addingTimeInterval(2), notBefore: Date = .distantPast, maxSide: Double = 960) async throws -> ObservationFrame {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard self.sampleContinuation == nil else { continuation.resume(throwing: VisionFailure.busy); return }
                    self.sampleID = id; self.sampleContinuation = continuation; self.notBefore = notBefore; self.sampleSide = maxSide
                    do { try self.configure() } catch { self.finishSample(.failure(error)) }
                    self.queue.asyncAfter(deadline: .now()+max(0,deadline.timeIntervalSinceNow)) {
                        if self.sampleID == id { self.finishSample(.failure(VisionFailure.timeout)) }
                    }
                }
            }
        } onCancel: { self.queue.async { if self.sampleID == id { self.finishSample(.failure(CancellationError())) } } }
    }
    private func finishSample(_ result: Result<ObservationFrame, any Error>) {
        let pending = sampleContinuation; sampleContinuation = nil
        stopIfIdle(); pending?.resume(with: result)
    }
    func preview(fps: Int, deliver: @escaping @Sendable (InspectionImage) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try self.configure()
                    self.previewInterval = 1 / Double(max(1, min(5, fps)))
                    self.previewSink = deliver
                    continuation.resume()
                } catch { continuation.resume(throwing: VisionFailure.unavailable) }
            }
        }
    }
    func stopPreview() {
        queue.async { self.previewSink = nil; self.stopIfIdle() }
    }
    func photo(deadline: Date) async throws -> CapturedImage {
        let requested = Date()
        let frame = try await sample(deadline: min(deadline,requested.addingTimeInterval(10)),notBefore: requested,maxSide: 1280)
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let encodingStart = Date()
                    let jpeg = try Self.jpeg(frame.image,quality: 0.75,limit: VisualEvidence.maxMediaBytes)
                    guard Date() < deadline else { throw VisionFailure.timeout }
                    continuation.resume(returning: CapturedImage(jpeg: jpeg,capturedAt: frame.capturedAt,cameraID: frame.cameraID,
                        width: frame.image.width,height: frame.image.height,captureDuration: encodingStart.timeIntervalSince(requested),encodingDuration: Date().timeIntervalSince(encodingStart)))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func releaseCamera() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.previewSink = nil
                self.finishSample(.failure(VisionFailure.staleSession))
                if self.session.isRunning { self.session.stopRunning() }
                continuation.resume()
            }
        }
    }
    private func stopIfIdle() {
        if !observationDemand && previewSink == nil && sampleContinuation == nil && session.isRunning { session.stopRunning() }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // One pending sample; late buffers are discarded by AVFoundation.
        guard sampleContinuation != nil || (previewSink != nil && Date().timeIntervalSince(lastPreview) >= previewInterval),
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), let clock = session.synchronizationClock else { return }
        let offset = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) - CMTimeGetSeconds(CMClockGetTime(clock))
        guard offset.isFinite, abs(offset) <= 2 else { return }
        let captured = Date().addingTimeInterval(offset)
        lastPreview = Date()
        autoreleasepool {
            let source = CIImage(cvPixelBuffer: buffer)
            if sampleContinuation != nil, captured >= notBefore {
                let factor = min(1,sampleSide / max(source.extent.width,source.extent.height))
                let sampled = source.transformed(by: CGAffineTransform(scaleX: factor,y: factor))
                if let cg = context.createCGImage(sampled,from: sampled.extent.integral) {
                    finishSample(.success(ObservationFrame(image: cg,capturedAt: captured,diagnostic: nil)))
                } else { finishSample(.failure(VisionFailure.internalError)) }
            }
            guard let sink = previewSink else { return }
            let scale = min(1, 640 / max(source.extent.width, source.extent.height))
            let image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = context.createCGImage(image, from: image.extent.integral),
                  let jpeg = try? Self.jpeg(cg, quality: 0.6, limit: 98_304) else { return }
            sink(InspectionImage(jpeg: jpeg, capturedAt: captured, width: cg.width, height: cg.height))
        }
    }
    private static func jpeg(_ image: CGImage, quality: Double, limit: Int) throws -> Data {
        let interval = PerformanceInterval("CameraJPEGEncode")
        defer { interval.end() }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { throw VisionFailure.internalError }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), jpeg.length <= limit else { throw VisionFailure.invalidArgument }
        return jpeg as Data
    }
}
