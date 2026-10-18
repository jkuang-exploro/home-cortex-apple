import Foundation
import Observation
import UIKit

@MainActor @Observable final class InspectionPublisher {
    private(set) var status = "Idle — no viewer"
    private(set) var isPublishing = false {
        didSet { wakefulness(isPublishing) }
    }
    private(set) var published = 0
    var paused = false
    @ObservationIgnored private let camera: any InspectionCamera
    @ObservationIgnored private let wakefulness: @MainActor (Bool) -> Void
    @ObservationIgnored private var frames: LatestValueChannel<PreviewSample>?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var uploader: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var transport: (any InspectionTransport)?
    @ObservationIgnored private var bodyID: String?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var expiresAt = Date.distantPast
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sequence: Int64 = 0
    @ObservationIgnored private var previewEpoch = 0
    init(camera: any InspectionCamera, wakefulness: @escaping @MainActor (Bool) -> Void = {
        UIApplication.shared.isIdleTimerDisabled = $0
    }) {
        self.camera = camera
        self.wakefulness = wakefulness
    }
    func stop() {
        previewEpoch += 1
        isPublishing = false
        generation += 1
        worker?.cancel(); uploader?.cancel(); expiryTask?.cancel()
        worker = nil; uploader = nil; expiryTask = nil
        transport = nil; bodyID = nil; sessionID = nil; expiresAt = .distantPast
        frames?.finish(); frames = nil
        camera.stopPreview(); status = paused ? "Paused on this iPhone" : "Idle — no viewer"
    }
    static func frame(_ image: InspectionImage, body: String, sequence: Int64) throws -> JSONValue {
        guard image.jpeg.count <= 98_304, image.width > 0, image.height > 0,
              image.width <= 960, image.height <= 960, image.width * image.height <= 960 * 540 else { throw VisionFailure.invalidArgument }
        return .object(["embodiment_id": .string(body), "camera_id": .string("rear.main"), "sequence": .integer(sequence),
            "captured_at": .string(V1Time.format(image.capturedAt)), "width": .integer(Int64(image.width)),
            "height": .integer(Int64(image.height)), "mime_type": .string("image/jpeg"), "media": .string(image.jpeg.base64EncodedString())])
    }
    func start(connection: ConnectionController) {
        start(access: { guard connection.displayedState == .connected, let credential = connection.credential,
                             credential.visionObserveGranted == true, let body = credential.embodimentID,
                             let session = connection.session?.sessionID else { throw ClientFailure.transport }
            return (body, session, try connection.inspectionTransport())
        }, active: { [weak self] in connection.displayedState == .connected && connection.session?.sessionID == self?.sessionID })
    }
    func start(access: @escaping @MainActor () throws -> (String, String, any InspectionTransport),
               active: @escaping @MainActor () -> Bool) {
        guard worker == nil else { return }
        generation += 1
        let token = generation
        let frames = LatestValueChannel<PreviewSample>()
        self.frames = frames
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, token == generation else { return }
                do {
                    guard !paused else { throw CancellationError() }
                    let context = try access()
                    if sessionID != context.1 {
                        stopPublication(status: "Idle — no viewer")
                        bodyID = context.0; sessionID = context.1; transport = context.2
                    }
                    guard let transport else { throw ClientFailure.transport }
                    let raw = try await transport.send(bodyID: context.0, sessionID: context.1, frame: nil)
                    guard token == generation, !Task.isCancelled, active() else { throw CancellationError() }
                    try await applyLease(raw, session: context.1, token: token, frames: frames, active: active)
                } catch {
                    guard token == generation else { return }
                    stopPublication(status: paused ? "Paused on this iPhone" : "Preview unavailable or no active session")
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        uploader = Task { [weak self] in
            for await sample in frames.stream {
                guard let self, token == generation, !Task.isCancelled else { return }
                let image = sample.image
                guard !paused, active(), expiresAt > Date(), let bodyID, let sessionID,
                      sample.session == sessionID, sample.epoch == previewEpoch, let transport,
                      Date().timeIntervalSince(image.capturedAt) >= 0,
                      Date().timeIntervalSince(image.capturedAt) <= 1 else { continue }
                sequence += 1
                do {
                    let frame = try Self.frame(image, body: bodyID, sequence: sequence)
                    guard try await transport.send(bodyID: bodyID, sessionID: sessionID, frame: frame) == .null else { throw ClientFailure.invalidResponse }
                    if token == generation, self.sessionID == sessionID, active(), sample.epoch == previewEpoch { published += 1 }
                } catch { /* Inspection drops samples; canonical traffic proceeds independently. */ }
            }
        }
    }
    private func stopPublication(status: String) {
        previewEpoch += 1
        expiryTask?.cancel(); expiryTask = nil
        isPublishing = false; expiresAt = .distantPast
        camera.stopPreview()
        self.status = status
    }
    private func applyLease(_ raw: JSONValue, session: String, token: Int,
                            frames: LatestValueChannel<PreviewSample>, active: @MainActor () -> Bool) async throws {
        let lease = try raw.object(required: ["active", "fps", "expires_at"])
        guard lease["active"] == .bool(true) else { stopPublication(status: "Idle — no viewer"); return }
        guard case .integer(let fps) = lease["fps"], (1...5).contains(fps) else { throw ClientFailure.invalidResponse }
        let expiry = try V1Time.parse(lease.field("expires_at").string())
        guard expiry > Date(), expiry.timeIntervalSinceNow <= 15 else { throw ClientFailure.invalidResponse }
        expiresAt = expiry
        let epoch = previewEpoch
        try await camera.startPreview(fps: Int(fps)) { frames.send(PreviewSample(session: session, epoch: epoch, image: $0)) }
        guard token == generation, !Task.isCancelled, epoch == previewEpoch, active() else { throw CancellationError() }
        isPublishing = true; status = "Publishing developer preview"
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) } catch { return }
            guard let self, token == generation, epoch == previewEpoch else { return }
            stopPublication(status: "Idle — viewer lease expired")
        }
    }
}

private struct PreviewSample: Sendable {
    let session: String
    let epoch: Int
    let image: InspectionImage
}
