import Foundation
import Observation
import OSLog

@MainActor @Observable final class VisionRuntime {
    let camera: any StillImageCapture
    var configured = false
    private(set) var captures = 0
    private(set) var lastCommand: JSONValue?
    private(set) var lastEvidenceID: String?
    @ObservationIgnored var mediaLimit = VisualEvidence.maxMediaBytes
    private(set) var lastTiming: String?
    private(set) var lastError: String?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var receipts: (identity: String, store: VisionReceipts)?
    @ObservationIgnored private var pending: [String: JSONValue] = [:]
    @ObservationIgnored private var waiters: [String: [CheckedContinuation<JSONValue, Never>]] = [:]
    @ObservationIgnored private let logger = Logger(subsystem: "HomeCortex", category: "Vision")
    init(camera: (any StillImageCapture)? = nil) { self.camera = camera ?? NativeStillImageCapture() }
    var manifest: JSONValue {
        guard configured else { return .object(["revision": .integer(1), "capabilities": .array([])]) }
        var entry: [String: JSONValue] = ["name": .string("vision.observe"), "schema_version": .integer(1),
            "availability": .string(camera.availability == nil ? "AVAILABLE" : "TEMPORARILY_UNAVAILABLE"),
            "limits": .object(["max_media_bytes": .integer(Int64(mediaLimit))])]
        if let failure = camera.availability { entry["reason"] = failure.wire }
        let capability = JSONValue.object(entry)
        return .object(["revision": .integer(1), "capabilities": .array([capability])])
    }
    func requestPermission() async { await camera.requestPermission() }
    func stop() { worker?.cancel(); worker = nil; camera.cancel() }
    func start(connection: ConnectionController) {
        guard configured, worker == nil else { return }
        worker = Task { [weak self, weak connection] in
            var nextReap = Date.distantPast
            var transportSession: String?
            var cachedTransport: (any V1Transport)?
            while !Task.isCancelled {
                guard let self, let connection else { return }
                do {
                    if Date() >= nextReap { try await receipts?.store.reap(); nextReap = Date().addingTimeInterval(60) }
                    if connection.displayedState == .connected, let credential = connection.credential,
                       let body = credential.embodimentID, let session = connection.session?.sessionID {
                        mediaLimit = min(VisualEvidence.maxMediaBytes, connection.maxMediaBytes)
                        if transportSession != session { cachedTransport = try connection.deviceTransport(); transportSession = session }
                        guard let transport = cachedTransport else { throw ClientFailure.transport }
                        let listing = try await transport.send(path: "/client-interface/v1/commands?session_id=" + session.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!, body: nil)
                        let fields = try listing.object(required: ["commands", "next_cursor"])
                        guard case .array(let commands) = try fields.field("commands"), commands.count <= 128 else { throw ClientFailure.invalidResponse }
                        for raw in commands {
                            try Task.checkCancellation()
                            let requestReceived = Date()
                            let reply = try await fulfill(raw, body: body, session: session, identity: credential.clientID, effective: connection.session?.effectiveCapabilities.contains("vision.observe") == true) {
                                connection.displayedState == .connected && connection.session?.sessionID == session
                            }
                            guard connection.displayedState == .connected, connection.session?.sessionID == session else { break }
                            guard try await receipts?.store.isAcknowledged(reply) != true else { continue }
                            let upload = Date()
                            guard try await transport.send(path: "/client-interface/v1/messages", body: reply) == .null else { throw ClientFailure.invalidResponse }
                            try await receipts?.store.acknowledge(reply)
                            let ms = Int(Date().timeIntervalSince(upload) * 1000)
                            logger.info("vision.observe response acknowledged, upload ms: \(ms, privacy: .public)")
                            lastTiming = (lastTiming ?? "") + "; upload \(ms) ms; vision.observe \(Int(Date().timeIntervalSince(requestReceived) * 1000)) ms"
                        }
                    }
                    try await Task.sleep(for: .milliseconds(350))
                } catch is CancellationError { return }
                catch {
                    lastError = (error as? VisionFailure)?.message ?? "Vision command transport is unavailable."
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
    }
    func fulfill(_ raw: JSONValue, body: String, session: String, identity: String, root: URL? = nil, effective: Bool = true,
                 active: () -> Bool = { true }) async throws -> JSONValue {
        let received = Date()
        let command = try VisionCommand(raw, body: body, session: session)
        lastCommand = raw
        let binding = identity + "\n" + body
        let pendingKey = binding + "\n" + command.id
        if let original = pending[pendingKey] {
            guard original == raw else { return command.reply(error: .conflict) }
            guard (waiters[pendingKey]?.count ?? 0) < 8 else { return command.reply(error: .busy) }
            return await withCheckedContinuation { waiters[pendingKey, default: []].append($0) }
        }
        guard pending.isEmpty else { return command.reply(error: .busy) }
        if receipts?.identity != binding {
            receipts = (binding, try VisionReceipts(identity: binding, root: root))
        }
        guard let receipts = receipts?.store else { throw VisionFailure.internalError }
        var reply = command.reply(error: .internalError)
        pending[pendingKey] = raw
        defer {
            pending.removeValue(forKey: pendingKey)
            for waiter in waiters.removeValue(forKey: pendingKey) ?? [] { waiter.resume(returning: reply) }
        }
        let outcome: (Bool, JSONValue?)
        do { outcome = try await receipts.begin(command) }
        catch let failure as VisionFailure { reply = command.reply(error: failure); return reply }
        if let previous = outcome.1 { reply = previous; return reply }
        do {
            guard outcome.0 else { throw VisionFailure.internalError }
            guard configured else { throw VisionFailure.permissionDenied }
            guard case .object(let fields) = command.value, fields["arguments"] == .object([:]) else { throw VisionFailure.invalidArgument }
            guard Date() < command.deadline else { throw VisionFailure.timeout }
            guard active() else { throw VisionFailure.staleSession }
            if let failure = camera.availability { throw failure }
            guard effective else { throw VisionFailure.unavailable }
            try Task.checkCancellation()
            let image = try await camera.captureFreshImage(deadline: command.deadline)
            captures += 1
            try Task.checkCancellation()
            guard active() else { throw VisionFailure.staleSession }
            guard image.capturedAt >= command.sentAt, Date() < command.deadline else { throw VisionFailure.timeout }
            guard image.jpeg.count <= mediaLimit else { throw VisionFailure.invalidArgument }
            let packageStart = Date()
            let sequence = Int64(captures)
            let result = try await Task.detached { try VisualEvidence.package(image, body: body, sequence: sequence) }.value
            try Task.checkCancellation()
            guard Date() < command.deadline else { throw VisionFailure.timeout }
            if case .object(let fields) = result, case .object(let manifest) = fields["evidence"] {
                lastEvidenceID = try manifest.field("evidence_id").string()
            }
            lastTiming = "start \(Int(image.capturedAt.timeIntervalSince(received) * 1000)) ms; capture \(Int(image.captureDuration * 1000)) ms; encode \(Int((image.encodingDuration + Date().timeIntervalSince(packageStart)) * 1000)) ms; total \(Int(Date().timeIntervalSince(received) * 1000)) ms"
            logger.info("vision.observe fresh evidence packaged: \(self.lastTiming ?? "", privacy: .public)")
            lastError = nil
            reply = command.reply(result: result)
        } catch {
            let failure = error as? VisionFailure ?? (error is CancellationError ? .unavailable : .internalError)
            lastError = failure.message
            reply = command.reply(error: failure)
        }
        do { try await receipts.finish(command, response: reply) }
        catch { reply = command.reply(error: .internalError); throw error }
        return reply
    }
}
