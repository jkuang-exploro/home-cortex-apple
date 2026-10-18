import Foundation
import Observation

/// Local acquisition is independent of bounded detection, lease queries and uploads.
@MainActor @Observable final class LocalizationRuntime {
    let camera: NativeStillImageCapture
    let calibration = SpatialCalibrationSession()
    let visualCalibration = VisualAnchorCalibration()
    @ObservationIgnored private let source: any LocalizationCamera
    @ObservationIgnored private let anchorDetector: any VisualAnchorSolving
    var configured = false
    private(set) var published = 0
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var detectorWorker: Task<Void, Never>?
    @ObservationIgnored private var demandWorker: Task<Void, Never>?
    @ObservationIgnored private var uploader: Task<Void, Never>?
    @ObservationIgnored private var updates: LatestValueChannel<String>?
    @ObservationIgnored private var context: LocalizationAccess?
    @ObservationIgnored private var expiresAt = Date.distantPast
    @ObservationIgnored private var generation = 0

    init(camera: NativeStillImageCapture, source: (any LocalizationCamera)? = nil,
         detector: (any VisualAnchorSolving)? = nil) {
        self.camera = camera
        self.source = source ?? camera
        anchorDetector = detector ?? VisualAnchorDetector()
    }
    func stop() {
        generation += 1
        worker?.cancel(); detectorWorker?.cancel(); demandWorker?.cancel(); uploader?.cancel()
        worker = nil; detectorWorker = nil; demandWorker = nil; uploader = nil
        updates?.finish(); updates = nil
        resetSession("Spatial tracking stopped. Relocalization is required.")
    }
    private func resetSession(_ reason: String) {
        source.stopTracking(); context = nil; expiresAt = .distantPast
        calibration.invalidate(reason); visualCalibration.invalidate(reason)
    }
    func start(connection: ConnectionController) {
        start(access: {
            guard connection.displayedState == .connected, let session = connection.session?.sessionID,
                  let body = connection.credential?.embodimentID else { return nil }
            return LocalizationAccess(body: body, session: session,
                transport: try connection.inspectionTransport(requireCamera: false))
        }, active: { connection.displayedState == .connected && connection.session?.sessionID == $0 })
    }
    func start(access: @escaping @MainActor () throws -> LocalizationAccess?,
               active: @escaping @MainActor (String) -> Bool) {
        guard configured, worker == nil else { return }
        let token = generation
        let updates = LatestValueChannel<String>()
        self.updates = updates
        worker = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self, token == generation else { return }
                if configured, let next = try? access(), active(next.session) {
                    if context?.session != next.session {
                        resetSession("DEVICE session changed. Relocalize after reconnecting.")
                        context = next
                        await source.useTracking(true)
                        guard token == generation, !Task.isCancelled else { return }
                        guard active(next.session) else { resetSession("DEVICE disconnected."); continue }
                    }
                    sample(session: next.session)
                    if expiresAt > Date() { updates.send(next.session) }
                } else if context != nil {
                    resetSession("DEVICE disconnected. Relocalize after reconnecting.")
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        detectorWorker = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self, token == generation else { return }
                if configured, let context, active(context.session), visualCalibration.needsVisualObservations {
                    await detect(session: context.session, token: token, active: active)
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        demandWorker = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self, token == generation else { return }
                if let context, active(context.session) { await refreshLease(context, token: token, active: active) }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        uploader = Task(priority: .utility) { [weak self] in
            var nextSend = ContinuousClock.now
            for await session in updates.stream {
                guard let self, token == generation, !Task.isCancelled else { return }
                guard let context, context.session == session, active(session), expiresAt > Date() else { continue }
                do { try await Task.sleep(until: nextSend, clock: .continuous) } catch { return }
                guard configured, token == generation, self.context?.session == session,
                      active(session), expiresAt > Date(), expiresAt.timeIntervalSinceNow <= 15 else { continue }
                guard case .object(var fields) = source.localTracking.diagnostic(body: context.body) else { continue }
                if let visual = visualCalibration.diagnostic { fields["calibration"] = visual }
                else if let geometric = calibration.diagnostic { fields["calibration"] = geometric }
                nextSend = .now.advanced(by: .milliseconds(500))
                do {
                    _ = try await context.transport.sendLocalization(bodyID: context.body, sessionID: session, diagnostic: .object(fields))
                    if token == generation, self.context?.session == session, active(session) { published += 1 }
                } catch { /* Drop; never replay diagnostics. */ }
            }
        }
    }
    private func sample(session: String) {
        let tracking = source.localTracking
        tracking.poll()
        calibration.update(worldID: tracking.worldID, deviceSession: session,
            cameraPose: tracking.cameraPose, trackingHealthy: tracking.state == .unanchored, measuredAt: tracking.measuredAt)
        visualCalibration.update(worldID: tracking.worldID, session: session,
            camera: tracking.cameraPose, healthy: tracking.state == .unanchored, measuredAt: tracking.measuredAt)
    }
    private func detect(session: String, token: Int, active: @MainActor (String) -> Bool) async {
        let scanGeneration = visualCalibration.generation
        do {
            let frame = try source.localTracking.visualFrame()
            let solution = try await anchorDetector.solve(frame: frame, tags: visualCalibration.tags)
            guard token == generation, !Task.isCancelled, configured, active(session), context?.session == session,
                  scanGeneration == visualCalibration.generation, source.localTracking.worldID == frame.worldID,
                  source.localTracking.state == .unanchored else { return }
            try visualCalibration.receive(solution: solution, frame: frame, session: session)
        } catch {
            if token == generation, !Task.isCancelled, scanGeneration == visualCalibration.generation,
               context?.session == session, active(session) { visualCalibration.detectionFailed(error) }
        }
    }
    private func refreshLease(_ context: LocalizationAccess, token: Int, active: @MainActor (String) -> Bool) async {
        do {
            let raw = try await context.transport.sendLocalization(bodyID: context.body, sessionID: context.session, diagnostic: nil)
            guard token == generation, !Task.isCancelled, self.context?.session == context.session, active(context.session) else { return }
            let fields = try raw.object(required: ["active", "fps", "expires_at"])
            let expiry = fields["active"] == .bool(true) ? try V1Time.parse(fields.field("expires_at").string()) : .distantPast
            expiresAt = expiry > Date() && expiry.timeIntervalSinceNow <= 15 ? expiry : .distantPast
        } catch {
            if token == generation, self.context?.session == context.session { expiresAt = .distantPast }
        }
    }
}
