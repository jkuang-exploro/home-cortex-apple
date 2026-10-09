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
@MainActor final class NativeStillImageCapture: StillImageCapture, InspectionCamera {
    let tracking = ARLocalTracking()
    private let engine = CameraEngine()
    private var trackingDesired = false
    private var ownershipGeneration = 0
    private var arPreview: Task<Void, Never>?
    private var photographing = false
    private var unavailableUntil: Date?
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
        if let unavailableUntil, unavailableUntil > Date() { return .unavailable }
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
        do {
            if trackingDesired {
                do { return try await tracking.freshImage(deadline: deadline) }
                catch {
                    try Task.checkCancellation()
                    guard Date() < deadline else { throw VisionFailure.timeout }
                    // A real new exposure has priority. Any camera handoff starts a new tracking world.
                    tracking.stop()
                    do {
                        let image = try await engine.photo(deadline: deadline)
                        await engine.releaseCamera()
                        if trackingDesired { tracking.start(resetReason: "Fresh evidence required camera handoff; new unanchored world") }
                        return image
                    } catch {
                        await engine.releaseCamera()
                        if trackingDesired { tracking.start(resetReason: "Evidence camera handoff failed; new unanchored world") }
                        throw error
                    }
                }
            }
            return try await withTaskCancellationHandler {
                try await engine.photo(deadline: deadline)
            } onCancel: { self.engine.cancelPhoto() }
        } catch {
            if error as? VisionFailure == .unavailable { unavailableUntil = Date().addingTimeInterval(2) }
            throw error
        }
    }
    func cancel() { engine.cancelPhoto(); tracking.cancelCapture() }
    func useTracking(_ enabled: Bool) async {
        ownershipGeneration += 1
        let token = ownershipGeneration
        trackingDesired = enabled
        if !enabled { tracking.stop(); arPreview?.cancel(); arPreview = nil; return }
        guard availability == nil else { tracking.stop(); return }
        await engine.releaseCamera()
        guard token == ownershipGeneration, trackingDesired else { return }
        tracking.start()
    }
    func stopTracking() {
        ownershipGeneration += 1; trackingDesired = false; tracking.stop(); arPreview?.cancel(); arPreview = nil
    }
    func startPreview(fps: Int, deliver: @escaping @Sendable (InspectionImage) -> Void) async throws {
        if let availability { throw availability }
        if trackingDesired {
            guard arPreview == nil else { return }
            arPreview = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, trackingDesired else { return }
                    if let image = try? await tracking.previewImage(), !Task.isCancelled { deliver(image) }
                    do { try await Task.sleep(for: .milliseconds(1000 / max(1, min(5, fps)))) } catch { return }
                }
            }
            return
        }
        try await engine.preview(fps: fps, deliver: deliver)
    }
    func stopPreview() { arPreview?.cancel(); arPreview = nil; engine.stopPreview() }
}

/// Mutable AVFoundation state and encoding run on one bounded, serial camera queue.
private final class CameraEngine: NSObject, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "HomeCortex.Camera", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var configured = false
    private var photoContinuation: CheckedContinuation<CapturedImage, any Error>?
    private var photoID: Int64?
    private var deadline = Date.distantPast
    private var captureTime: Date?
    private var started = Date()
    private var previewSink: (@Sendable (InspectionImage) -> Void)?
    private var previewInterval = 1.0 / 3
    private var lastPreview = Date.distantPast
    private func configure() throws {
        if !configured {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw VisionFailure.unavailable }
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720
            guard session.canAddInput(input), session.canAddOutput(photoOutput), session.canAddOutput(videoOutput) else {
                session.commitConfiguration(); throw VisionFailure.unavailable
            }
            session.addInput(input); session.addOutput(photoOutput); session.addOutput(videoOutput)
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.setSampleBufferDelegate(self, queue: queue)
            for output in [photoOutput as AVCaptureOutput, videoOutput] {
                if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            }
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
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.photoContinuation == nil else { continuation.resume(throwing: VisionFailure.busy); return }
                self.photoContinuation = continuation
                self.deadline = min(deadline, Date().addingTimeInterval(10))
                self.captureTime = nil
                do {
                    guard Date() < self.deadline else { throw VisionFailure.timeout }
                    try self.configure()
                    let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                    settings.photoQualityPrioritization = .speed
                    self.photoID = settings.uniqueID
                    self.started = Date()
                    self.photoOutput.capturePhoto(with: settings, delegate: self)
                    let id = settings.uniqueID
                    self.queue.asyncAfter(deadline: .now() + max(0, self.deadline.timeIntervalSinceNow)) {
                        if self.photoID == id { self.finishPhoto(.failure(VisionFailure.timeout)) }
                    }
                } catch { self.finishPhoto(.failure(error as? VisionFailure ?? .unavailable)) }
            }
        }
    }
    func cancelPhoto() { queue.async { self.finishPhoto(.failure(CancellationError())) } }
    func releaseCamera() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.previewSink = nil
                self.finishPhoto(.failure(CancellationError()))
                if self.session.isRunning { self.session.stopRunning() }
                continuation.resume()
            }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor settings: AVCaptureResolvedPhotoSettings) {
        let time = Date(); let id = settings.uniqueID
        queue.async { if self.photoID == id { self.captureTime = time } }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        let raw = photo.fileDataRepresentation(); let failed = error != nil; let id = photo.resolvedSettings.uniqueID
        queue.async {
            guard self.photoID == id else { return }
            do {
                guard !failed, let raw, let time = self.captureTime else { throw VisionFailure.unavailable }
                guard Date() < self.deadline else { throw VisionFailure.timeout }
                let captureDuration = Date().timeIntervalSince(self.started)
                let encodingStart = Date()
                guard let source = CGImageSourceCreateWithData(raw as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1280
                      ] as CFDictionary) else { throw VisionFailure.internalError }
                let jpeg = try Self.jpeg(image, quality: 0.75, limit: VisualEvidence.maxMediaBytes)
                self.finishPhoto(.success(CapturedImage(jpeg: jpeg, capturedAt: time, cameraID: "camera:rear-primary",
                    width: image.width, height: image.height, captureDuration: captureDuration,
                    encodingDuration: Date().timeIntervalSince(encodingStart))))
            } catch { self.finishPhoto(.failure(error as? VisionFailure ?? .internalError)) }
        }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor settings: AVCaptureResolvedPhotoSettings, error: (any Error)?) {
        if error != nil { let id = settings.uniqueID; queue.async { if self.photoID == id { self.finishPhoto(.failure(VisionFailure.unavailable)) } } }
    }
    private func finishPhoto(_ result: Result<CapturedImage, any Error>) {
        let continuation = photoContinuation
        photoContinuation = nil; photoID = nil
        stopIfIdle()
        continuation?.resume(with: result)
    }
    private func stopIfIdle() {
        if previewSink == nil && photoContinuation == nil && session.isRunning { session.stopRunning() }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Photo commands take priority. Late buffers are discarded by AVFoundation.
        guard photoContinuation == nil, let sink = previewSink, Date().timeIntervalSince(lastPreview) >= previewInterval,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), let clock = session.synchronizationClock else { return }
        let offset = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) - CMTimeGetSeconds(CMClockGetTime(clock))
        guard offset.isFinite, abs(offset) <= 2 else { return }
        let captured = Date().addingTimeInterval(offset)
        lastPreview = Date()
        autoreleasepool {
            let source = CIImage(cvPixelBuffer: buffer)
            let scale = min(1, 640 / max(source.extent.width, source.extent.height))
            let image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = context.createCGImage(image, from: image.extent.integral),
                  let jpeg = try? Self.jpeg(cg, quality: 0.6, limit: 98_304) else { return }
            sink(InspectionImage(jpeg: jpeg, capturedAt: captured, width: cg.width, height: cg.height))
        }
    }
    private static func jpeg(_ image: CGImage, quality: Double, limit: Int) throws -> Data {
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { throw VisionFailure.internalError }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), jpeg.length <= limit else { throw VisionFailure.invalidArgument }
        return jpeg as Data
    }
}
