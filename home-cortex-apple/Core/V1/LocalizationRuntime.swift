import Foundation
import Observation

/// Latest-only 2 Hz diagnostic publication; no canonical authority is inferred.
@MainActor @Observable final class LocalizationRuntime {
    let camera: NativeStillImageCapture
    let calibration = SpatialCalibrationSession()
    let visualCalibration = VisualAnchorCalibration()
    @ObservationIgnored private let anchorDetector = VisualAnchorDetector()
    var configured = false
    private(set) var published = 0
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    init(camera: NativeStillImageCapture) { self.camera = camera }
    func stop() { generation += 1; worker?.cancel(); worker = nil; camera.stopTracking(); calibration.invalidate("Spatial tracking stopped. Relocalization is required."); visualCalibration.invalidate("Spatial tracking stopped. Face an anchor to recalibrate.") }
    func start(connection: ConnectionController) {
        guard configured, worker == nil else { return }
        let token = generation
        worker = Task(priority: .utility) { [weak self] in
            var activeSession: String?
            var transport: (any InspectionTransport)?
            var expiry = Date.distantPast
            var queried = Date.distantPast
            var sent = Date.distantPast
            var detected = Date.distantPast
            while !Task.isCancelled {
                guard let self, token == generation else { return }
                if !configured || connection.displayedState != .connected {
                    camera.stopTracking(); activeSession = nil; transport = nil; expiry = .distantPast
                    calibration.invalidate("DEVICE disconnected. Relocalize after reconnecting.")
                    visualCalibration.invalidate("DEVICE disconnected. Face an anchor after reconnecting.")
                } else if let session = connection.session?.sessionID, let body = connection.credential?.embodimentID {
                    if activeSession != session {
                        camera.stopTracking(); activeSession = session; expiry = .distantPast
                        transport = try? connection.inspectionTransport(requireCamera: false)
                        await camera.useTracking(true)
                        guard token == generation, !Task.isCancelled else { camera.stopTracking(); return }
                    }
                    camera.tracking.poll()
                    calibration.update(worldID: camera.tracking.worldID, deviceSession: session,
                        cameraPose: camera.tracking.cameraPose, trackingHealthy: camera.tracking.state == .unanchored,
                        measuredAt: camera.tracking.measuredAt)
                    visualCalibration.update(worldID: camera.tracking.worldID, session: session,
                        camera: camera.tracking.cameraPose, healthy: camera.tracking.state == .unanchored,
                        measuredAt: camera.tracking.measuredAt)
                    if visualCalibration.needsVisualObservations, Date().timeIntervalSince(detected) >= 0.25 {
                        detected = Date()
                        let scanGeneration = visualCalibration.generation
                        do {
                            let frame = try camera.tracking.visualFrame()
                            let solution = try await anchorDetector.solve(frame: frame, tags: visualCalibration.tags)
                            guard token == generation, !Task.isCancelled else { return }
                            guard scanGeneration == visualCalibration.generation,
                                  camera.tracking.worldID == frame.worldID,
                                  camera.tracking.state == .unanchored,
                                  connection.session?.sessionID == session else { continue }
                            try visualCalibration.receive(solution: solution, frame: frame, session: session)
                        } catch {
                            if token == generation && scanGeneration == visualCalibration.generation {
                                visualCalibration.detectionFailed(error)
                            }
                        }
                    }
                    if Date().timeIntervalSince(queried) >= 1, let transport {
                        queried = Date()
                        do {
                            let raw = try await transport.sendLocalization(bodyID: body, sessionID: session, diagnostic: nil)
                            let fields = try raw.object(required: ["active", "fps", "expires_at"])
                            expiry = fields["active"] == .bool(true) ? (try? V1Time.parse(fields.field("expires_at").string())) ?? .distantPast : .distantPast
                        } catch { expiry = .distantPast }
                    }
                    guard token == generation, !Task.isCancelled else { return }
                    if expiry > Date(), expiry.timeIntervalSinceNow <= 15, Date().timeIntervalSince(sent) >= 0.5,
                       connection.session?.sessionID == session, let transport, case .object(var fields) = camera.tracking.diagnostic(body: body) {
                        if let visual = visualCalibration.diagnostic { fields["calibration"] = visual }
                        else if let calibration = calibration.diagnostic { fields["calibration"] = calibration }
                        let value = JSONValue.object(fields)
                        sent = Date()
                        do {
                            _ = try await transport.sendLocalization(bodyID: body, sessionID: session, diagnostic: value)
                            if token == generation { published += 1 }
                        } catch { /* Drop; no replay of local sensor data. */ }
                    }
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }
}
