import Foundation
import Observation
import UIKit

protocol InspectionTransport: Sendable {
    func send(bodyID: String, sessionID: String, frame: JSONValue?) async throws -> JSONValue
}

final class URLSessionInspectionTransport: InspectionTransport, @unchecked Sendable {
    private let origin: URL
    private let session: URLSession
    private let delegate: TLSDelegate
    init(configuration: ClientConfiguration, ca: String, identity: IdentityMaterial) throws {
        origin = configuration.serverEndpoint
        delegate = TLSDelegate(origin: origin, hostname: configuration.serverHostname,
            anchors: try CertificateTools.certificates(pem: ca), identity: identity)
        let config = URLSessionConfiguration.ephemeral
        config.tlsMinimumSupportedProtocolVersion = .TLSv13
        config.tlsMaximumSupportedProtocolVersion = .TLSv13
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        config.waitsForConnectivity = false
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    func send(bodyID: String, sessionID: String, frame: JSONValue?) async throws -> JSONValue {
        guard bodyID.range(of: "^embodiment:[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw ClientFailure.configuration }
        let path = "/inspection/v1/device/" + bodyID + (frame == nil ? "/lease" : "/frames")
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL, url.host == origin.host, url.port == origin.port else { throw ClientFailure.configuration }
        var request = URLRequest(url: url)
        request.httpMethod = frame == nil ? "GET" : "POST"
        request.setValue(sessionID, forHTTPHeaderField: "X-Cortex-Session")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let frame {
            let body = try JSONEncoder().encode(frame)
            guard body.count <= 140_000 else { throw ClientFailure.invalidResponse }
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (bytes, raw) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = raw as? HTTPURLResponse, (200..<300).contains(response.statusCode), bytes.count <= 8192 else { throw ClientFailure.transport }
        if response.statusCode == 204 { guard bytes.isEmpty else { throw ClientFailure.invalidResponse }; return .null }
        guard response.mimeType == "application/json" else { throw ClientFailure.invalidResponse }
        return try JSONValue.decode(bytes)
    }
}

/// One newest sample, even when the main actor or HTTPS consumer falls behind.
final class InspectionMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: InspectionImage?
    func put(_ image: InspectionImage) { lock.lock(); latest = image; lock.unlock() }
    func take() -> InspectionImage? { lock.lock(); defer { lock.unlock() }; let image = latest; latest = nil; return image }
    func clear() { lock.lock(); latest = nil; lock.unlock() }
}

@MainActor @Observable final class InspectionPublisher {
    private(set) var status = "Idle — no viewer"
    private(set) var isPublishing = false {
        didSet { wakefulness(isPublishing) }
    }
    private(set) var published = 0
    var paused = false
    @ObservationIgnored private let camera: any InspectionCamera
    @ObservationIgnored private let wakefulness: @MainActor (Bool) -> Void
    @ObservationIgnored private let mailbox = InspectionMailbox()
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var uploader: Task<Void, Never>?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var transport: (any InspectionTransport)?
    @ObservationIgnored private var bodyID: String?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var expiresAt = Date.distantPast
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sequence: Int64 = 0
    init(camera: any InspectionCamera, wakefulness: @escaping @MainActor (Bool) -> Void = {
        UIApplication.shared.isIdleTimerDisabled = $0
    }) {
        self.camera = camera
        self.wakefulness = wakefulness
    }
    func stop() {
        isPublishing = false
        generation += 1
        worker?.cancel(); uploader?.cancel(); expiryTask?.cancel()
        worker = nil; uploader = nil; expiryTask = nil
        transport = nil; bodyID = nil; sessionID = nil; expiresAt = .distantPast
        mailbox.clear(); camera.stopPreview(); status = paused ? "Paused on this iPhone" : "Idle — no viewer"
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
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    guard !paused else { throw CancellationError() }
                    let context = try access()
                    if sessionID != context.1 {
                        isPublishing = false
                        mailbox.clear(); camera.stopPreview(); expiresAt = .distantPast
                        bodyID = context.0; sessionID = context.1; transport = context.2
                    }
                    guard let transport else { throw ClientFailure.transport }
                    let raw = try await transport.send(bodyID: context.0, sessionID: context.1, frame: nil)
                    guard token == generation, !Task.isCancelled, active() else { throw CancellationError() }
                    let lease = try raw.object(required: ["active", "fps", "expires_at"])
                    if lease["active"] == .bool(true) {
                        guard case .integer(let fps) = lease["fps"], (1...5).contains(fps) else { throw ClientFailure.invalidResponse }
                        let expiry = try V1Time.parse(lease.field("expires_at").string())
                        guard expiry > Date(), expiry.timeIntervalSinceNow <= 15 else { throw ClientFailure.invalidResponse }
                        expiresAt = expiry
                        let mailbox = self.mailbox
                        try await camera.startPreview(fps: Int(fps)) { mailbox.put($0) }
                        guard token == generation, active() else { camera.stopPreview(); return }
                        isPublishing = true
                        status = "Publishing developer preview"
                        expiryTask?.cancel()
                        expiryTask = Task { [weak self] in
                            do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) } catch { return }
                            guard let self, token == generation else { return }
                            isPublishing = false
                            camera.stopPreview(); mailbox.clear(); expiresAt = .distantPast; status = "Idle — viewer lease expired"
                        }
                    } else {
                        isPublishing = false
                        camera.stopPreview(); mailbox.clear(); expiresAt = .distantPast; status = "Idle — no viewer"
                    }
                } catch {
                    guard token == generation else { return }
                    isPublishing = false
                    camera.stopPreview(); mailbox.clear(); expiresAt = .distantPast
                    status = paused ? "Paused on this iPhone" : "Preview unavailable or no active session"
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        uploader = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !paused, active(), expiresAt > Date(), let bodyID, let sessionID, let transport,
                   let image = mailbox.take(), Date().timeIntervalSince(image.capturedAt) <= 1 {
                    sequence += 1
                    do {
                        let frame = try Self.frame(image, body: bodyID, sequence: sequence)
                        guard try await transport.send(bodyID: bodyID, sessionID: sessionID, frame: frame) == .null else { throw ClientFailure.invalidResponse }
                        if token == generation { published += 1 }
                    } catch { /* Inspection drops samples; canonical traffic proceeds independently. */ }
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }
}
