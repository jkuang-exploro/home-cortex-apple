import CoreMotion
import Foundation
import Observation
import simd

/// Active Hamilton rotations: q(R←B) maps body components into reference components.
/// Apple A=(screen right, top, display out); B=(display out, screen right, top).
/// Both are right handed. Quaternion arrays are [x,y,z,w]; Euler is intrinsic ZYX, radians.
enum IPhoneBodyFrame {
    static let appleFromBody = simd_quatd(ix: -0.5, iy: -0.5, iz: -0.5, r: 0.5)
    static func nativeFromBody(_ nativeFromApple: simd_quatd) -> simd_quatd {
        simd_normalize(nativeFromApple * appleFromBody)
    }
    static func relative(initial: simd_quatd, current: simd_quatd) -> simd_quatd {
        simd_normalize(initial.inverse * current)
    }
    static func components(_ q: simd_quatd) -> [Double] { [q.imag.x, q.imag.y, q.imag.z, q.real] }
    static func euler(_ q: simd_quatd) -> SIMD3<Double> {
        let x = q.imag.x, y = q.imag.y, z = q.imag.z, w = q.real
        return SIMD3(atan2(2*(w*z+x*y), 1-2*(y*y+z*z)),
                     asin(max(-1, min(1, 2*(w*y-z*x)))),
                     atan2(2*(w*x+y*z), 1-2*(x*x+y*y)))
    }
    static func quaternion(yaw: Double, pitch: Double, roll: Double) -> simd_quatd {
        simd_quatd(angle: yaw, axis: SIMD3(0,0,1)) * simd_quatd(angle: pitch, axis: SIMD3(0,1,0)) * simd_quatd(angle: roll, axis: SIMD3(1,0,0))
    }
}

/// Partial geometry for the existing builtInWideAngleCamera(.back) capture.
/// No usable T(B←C) exists until optical rotation and translation are measured.
enum IPhoneRearCameraGeometry {
    static let nominalViewingDirectionBody = SIMD3<Double>(-1, 0, 0)
    static let opticalCenterBodyMeters: SIMD3<Double>? = nil
    static let calibratedBodyFromOptical: simd_quatd? = nil
    // Apple's documented ARKit axes, not the orientation-normalized JPEG pixel frame.
    static let nominalBodyFromARKitCamera = simd_quatd(angle: .pi / 2, axis: SIMD3(0,1,0))
}

struct LocalMotionAttitude: Sendable {
    let referenceID: String
    let sequence: Int64
    let measuredAt: Date
    let quaternion: simd_quatd
    let nativeBodyQuaternion: simd_quatd
    let gravityResidual: Double
    var angles: SIMD3<Double> { IPhoneBodyFrame.euler(quaternion) }
    func diagnostic(body: String) -> JSONValue {
        let a = angles
        return .object([
            "embodiment_id": .string(body), "reference_frame_id": .string(referenceID),
            "reference_frame": .string("initial_body_at_start"), "native_reference_frame": .string("xArbitraryZVertical"),
            "body_frame": .string("iphone.body.v1"), "source": .string("Core Motion"),
            "household_aligned": .bool(false), "uncertainty": .string("unknown"),
            "sequence": .integer(sequence), "measured_at": .string(V1Time.format(measuredAt)),
            "quaternion": .array(IPhoneBodyFrame.components(quaternion).map(JSONValue.number)),
            "native_body_quaternion": .array(IPhoneBodyFrame.components(nativeBodyQuaternion).map(JSONValue.number)),
            "yaw": .number(a.x), "pitch": .number(a.y), "roll": .number(a.z), "tracking_state": .string("ACTIVE")])
    }
}

/// Poll Core Motion's latest fused attitude; no raw integration, callback queue, or background work.
@MainActor @Observable final class MotionAcquisition {
    private(set) var status = "Off"
    private(set) var latest: LocalMotionAttitude?
    private(set) var referenceID: String?
    var available: Bool { manager.isDeviceMotionAvailable }
    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var initial: simd_quatd?
    @ObservationIgnored private var sequence: Int64 = 0
    @ObservationIgnored private var lastTimestamp = -Double.infinity
    func start() {
        stop()
        guard available, CMMotionManager.availableAttitudeReferenceFrames().contains(.xArbitraryZVertical) else {
            status = "Device motion unavailable"; return
        }
        referenceID = "motion:" + UUID().uuidString.lowercased()
        manager.deviceMotionUpdateInterval = 0.1
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical)
        status = "Starting Core Motion"
    }
    func stop() {
        manager.stopDeviceMotionUpdates()
        initial = nil; latest = nil; referenceID = nil; sequence = 0; lastTimestamp = -Double.infinity
        status = "Off"
    }
    @discardableResult func poll() -> LocalMotionAttitude? {
        guard let referenceID else { return nil }
        guard manager.isDeviceMotionActive else { latest = nil; status = "Device motion inactive"; return nil }
        guard let motion = manager.deviceMotion, motion.timestamp > lastTimestamp,
              ProcessInfo.processInfo.systemUptime - motion.timestamp < 0.3 else {
            if let latest, Date().timeIntervalSince(latest.measuredAt) > 0.5 { self.latest = nil; status = "Waiting for motion data" }
            return nil
        }
        let q = motion.attitude.quaternion
        let nativeFromApple = simd_normalize(simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w))
        let gravity = SIMD3(motion.gravity.x, motion.gravity.y, motion.gravity.z)
        // Runtime convention check; failure is unavailable, never an inferred heading/uncertainty.
        let residual = simd_length(nativeFromApple.act(gravity) - SIMD3(0,0,-1))
        guard residual.isFinite, residual < 0.15 else { latest = nil; status = "Motion frame check failed"; return nil }
        let nativeBody = IPhoneBodyFrame.nativeFromBody(nativeFromApple)
        if initial == nil { initial = nativeBody }
        sequence += 1; lastTimestamp = motion.timestamp
        let value = LocalMotionAttitude(referenceID: referenceID, sequence: sequence,
            measuredAt: Date().addingTimeInterval(motion.timestamp - ProcessInfo.processInfo.systemUptime),
            quaternion: IPhoneBodyFrame.relative(initial: initial!, current: nativeBody), nativeBodyQuaternion: nativeBody,
            gravityResidual: residual)
        latest = value; status = "Active · local, not household aligned"
        return value
    }
}

/// Independent low-priority HTTPS work, at most one upload and one demand request in flight.
@MainActor @Observable final class MotionOrientationRuntime {
    let acquisition = MotionAcquisition()
    var configured = false
    private(set) var published = 0
    private(set) var status = "Off"
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var demandWorker: Task<Void, Never>?
    @ObservationIgnored private var uploader: Task<Void, Never>?
    @ObservationIgnored private var expiresAt = Date.distantPast
    @ObservationIgnored private var transport: (any InspectionTransport)?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var bodyID: String?
    @ObservationIgnored private var lastSent: Int64 = 0
    @ObservationIgnored private var generation = 0
    func stop() {
        generation += 1
        worker?.cancel(); demandWorker?.cancel(); uploader?.cancel()
        worker = nil; demandWorker = nil; uploader = nil
        resetSession(); status = "Off"
    }
    private func resetSession() {
        acquisition.stop(); expiresAt = .distantPast; sessionID = nil; bodyID = nil; transport = nil; lastSent = 0
    }
    func start(connection: ConnectionController) {
        guard configured, worker == nil else { return }
        let token = generation
        worker = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self, token == generation else { return }
                if !configured || connection.displayedState != .connected {
                    resetSession(); status = configured ? "Waiting for DEVICE session" : "Off"
                } else if let session = connection.session?.sessionID, let body = connection.credential?.embodimentID {
                    if sessionID != session {
                        resetSession(); sessionID = session; bodyID = body
                        transport = try? connection.inspectionTransport(requireCamera: false)
                        acquisition.start()
                    }
                    acquisition.poll(); status = acquisition.status
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        demandWorker = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self, token == generation else { return }
                if let transport, let bodyID, let sessionID {
                    do {
                        let value = try await transport.sendOrientation(bodyID: bodyID, sessionID: sessionID, diagnostic: nil)
                        guard token == generation, self.sessionID == sessionID else { continue }
                        let fields = try value.object(required: ["active", "fps", "expires_at"])
                        if try fields.field("active") == .bool(true),
                           let expiry = try? V1Time.parse(fields.field("expires_at").string()), expiry > Date(), expiry.timeIntervalSinceNow <= 15 {
                            expiresAt = expiry
                        } else { expiresAt = .distantPast }
                    } catch { if self.sessionID == sessionID { expiresAt = .distantPast } }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        uploader = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self, token == generation else { return }
                if configured, connection.displayedState == .connected, expiresAt > Date(),
                   let sample = acquisition.latest, sample.sequence > lastSent, Date().timeIntervalSince(sample.measuredAt) < 0.3,
                   let bodyID, let sessionID, let transport {
                    lastSent = sample.sequence // Dropped on failure. Never retry or queue an old sample.
                    do {
                        _ = try await transport.sendOrientation(bodyID: bodyID, sessionID: sessionID, diagnostic: sample.diagnostic(body: bodyID))
                        if token == generation && self.sessionID == sessionID { published += 1 }
                    } catch { /* Lower priority diagnostics may drop; canonical operations remain independent. */ }
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }
}
