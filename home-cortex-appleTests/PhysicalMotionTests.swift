import XCTest
import UIKit
import simd
@testable import HomeCortex

final class PhysicalMotionTests: XCTestCase {
    @MainActor func testPhysicalEmbodimentConnectionRecovery() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the retained physical iPhone and production backend")
        #else
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        let caller = AppRuntime.connection, phone = AppRuntime.embodiment
        let retainedID = try XCTUnwrap(phone.embodimentID)
        caller.setForeground(true); caller.connect(); phone.setForeground(true); phone.enableRuntime()
        try await wait { caller.displayedState == .connected && phone.isOnline }
        await phone.refreshConfiguration(caller: caller)
        XCTAssertNil(phone.setupMessage)
        let configuration = try XCTUnwrap(phone.serverConfiguration)
        XCTAssertEqual(configuration.embodiment_id, retainedID)
        XCTAssertTrue(configuration.cameraEnabled)
        let (http, session, _) = try caller.embodimentSetupAccess()
        let requested = Date()
        let response = try JSONValue.decode(await http.send("/inspection/v1/embodiments/" + retainedID + "/evidence",
            sessionID: session, method: "POST", body: Data("{}".utf8))).inspectionFields(required: ["evidence_id", "captured_at", "embodiment_id"])
        XCTAssertEqual(response["embodiment_id"], .string(retainedID))
        let captured = try V1Time.parse(response.field("captured_at").string())
        XCTAssertGreaterThanOrEqual(captured.timeIntervalSince(requested), -0.1)
        XCTAssertLessThan(Date().timeIntervalSince(captured), 10)
        phone.setForeground(false); phone.setForeground(true)
        try await wait { phone.isOnline }
        await phone.refreshConfiguration(caller: caller)
        XCTAssertNil(phone.setupMessage)
        XCTAssertEqual(phone.embodimentID, retainedID)
        XCTAssertEqual(phone.serverConfiguration?.agent_id, configuration.agent_id)
        print("EMBODIMENT RECOVERY PASS: same retained body and agent; connected; fresh camera evidence; foreground reconnect")
        #endif
    }

    @MainActor func testPhysicalARKitCameraDiagnosticsAndCoexistence() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical ARKit camera and production backend")
        #else
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        let caller = AppRuntime.connection, phone = AppRuntime.embodiment
        caller.setForeground(true); caller.connect(); phone.setForeground(true); phone.enableRuntime()
        try await wait { caller.displayedState == .connected && phone.isOnline }
        await phone.refreshConfiguration(caller: caller)
        let originallyEnabled = phone.localizationSelected
        let body = try XCTUnwrap(phone.embodimentID)
        await phone.changeLocalization(true, caller: caller)
        XCTAssertNil(phone.setupMessage)
        let logger = Task { @MainActor in
            while !Task.isCancelled {
                print("ARKIT WAIT \(phone.localization.camera.tracking.debugStatus)")
                do { try await Task.sleep(for:.seconds(5)) } catch { return }
            }
        }
        defer { logger.cancel() }
        try await wait { phone.isOnline && phone.localization.camera.tracking.state == .unanchored }
        let tracker = phone.localization.camera.tracking
        XCTAssertTrue(tracker.running); XCTAssertNotNil(tracker.cameraPose)
        let firstWorld = try XCTUnwrap(tracker.worldID)
        let (http, session, _) = try caller.embodimentSetupAccess()
        let path = "/inspection/v1/embodiments/" + body
        let data = try await http.send(path+"/leases",sessionID:session,method:"POST",body:Data(#"{"channel":"localization","fps":2}"#.utf8))
        let lease = try JSONValue.decode(data).inspectionFields(required:["lease_id"]).field("lease_id").string()
        let cameraData = try await http.send(path+"/leases",sessionID:session,method:"POST",body:Data(#"{"channel":"camera","fps":3}"#.utf8))
        let cameraLease = try JSONValue.decode(cameraData).inspectionFields(required:["lease_id"]).field("lease_id").string()
        let renewer = Task { @MainActor in
            while !Task.isCancelled {
                for (id, channel, fps) in [(lease,"localization",2),(cameraLease,"camera",3)] {
                    let value = JSONValue.object(["lease_id":.string(id),"channel":.string(channel),"fps":.integer(Int64(fps))])
                    _ = try? await http.send(path+"/leases",sessionID:session,method:"POST",body:JSONEncoder().encode(value))
                }
                do { try await Task.sleep(for:.seconds(4)) } catch { return }
            }
        }
        defer { renewer.cancel() }
        let before = phone.localization.published
        try await wait { phone.localization.published >= before + 3 }
        let response = try JSONValue.decode(await http.send(path+"/localization?lease_id="+lease,sessionID:session)).inspectionFields(required:["diagnostic"])
        let diagnostic = try response.field("diagnostic").inspectionFields(required:["world_id","pose_frame","household_aligned","measured_at","camera_pose"])
        XCTAssertEqual(diagnostic["world_id"],.string(firstWorld))
        XCTAssertEqual(diagnostic["pose_frame"],.string("camera_optical")); XCTAssertEqual(diagnostic["household_aligned"],.bool(false))
        let measured = try V1Time.parse(diagnostic.field("measured_at").string())
        XCTAssertLessThan(Date().timeIntervalSince(measured),1)
        print("ARKIT LOCAL DIAGNOSTIC world=\(firstWorld) measured=\(measured) pose=\(String(describing: tracker.cameraPose))")
        let preview = try JSONValue.decode(await http.send(path+"/frames?lease_id="+cameraLease,sessionID:session)).inspectionFields(required:["frame"])
        XCTAssertNotEqual(preview["frame"],.null)
        let chat = try caller.conversationAccess()
        let conversation = try await chat.transport.selectOrCreate(sessionID:chat.sessionID)
        _ = try await chat.transport.setActive(id:conversation.id,embodimentID:body,sessionID:chat.sessionID)
        try await chat.transport.stream(id:conversation.id,content:"我是谁",sessionID:chat.sessionID) { _ in }
        let history = try await chat.transport.history(id:conversation.id,sessionID:chat.sessionID)
        XCTAssertFalse(history.messages.last?.content.isEmpty ?? true)
        let captures = phone.vision.captures
        let captureWorld = tracker.worldID
        try await chat.transport.stream(id:conversation.id,content:"你现在能看到什么？",sessionID:chat.sessionID) { _ in }
        XCTAssertGreaterThan(phone.vision.captures,captures)
        print("ARKIT VISION world_changed=\(captureWorld != tracker.worldID) timing=\(phone.vision.lastTiming ?? "unknown")")
        XCTAssertTrue(phone.isOnline); XCTAssertEqual(caller.displayedState,.connected)
        let oldWorld = tracker.worldID
        phone.setForeground(false); XCTAssertFalse(tracker.running); XCTAssertNil(tracker.cameraPose)
        phone.setForeground(true)
        try await wait { phone.isOnline && tracker.state == .unanchored }
        XCTAssertEqual(phone.embodimentID,body); XCTAssertNotEqual(tracker.worldID,oldWorld)
        await phone.changeLocalization(false,caller:caller)
        XCTAssertFalse(tracker.running); XCTAssertNil(tracker.cameraPose)
        let stopped = phone.localization.published
        try await Task.sleep(for:.seconds(1)); XCTAssertEqual(stopped,phone.localization.published)
        if originallyEnabled { await phone.changeLocalization(true,caller:caller) }
        _ = try? await http.send(path+"/leases/"+lease,sessionID:session,method:"DELETE")
        _ = try? await http.send(path+"/leases/"+cameraLease,sessionID:session,method:"DELETE")
        print("ARKIT LOCAL CAMERA CHAT HEARTBEAT LIFECYCLE OFF PASS; CANONICAL POSE UNAVAILABLE")
        #endif
    }
    @MainActor private func wait(timeoutSeconds: Int = 60, _ predicate: () -> Bool) async throws {
        for _ in 0..<(timeoutSeconds * 10) { if predicate() { return }; try await Task.sleep(for: .milliseconds(100)) }
        throw ChatFailure.timeout
    }
    @MainActor func testNativeInspectorLifecycleAndNonInterference() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical iPhone and production backend")
        #else
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        let caller = AppRuntime.connection, phone = AppRuntime.embodiment
        caller.setForeground(true); caller.connect(); phone.setForeground(true); phone.enableRuntime()
        try await wait { caller.displayedState == .connected && phone.isOnline }
        await phone.refreshConfiguration(caller: caller)
        let initiallyEnabled = phone.motionSelected
        let body = try XCTUnwrap(phone.embodimentID)
        await phone.changeMotion(true, caller: caller)
        XCTAssertNil(phone.setupMessage)
        try await wait { phone.isOnline && phone.motion.acquisition.latest != nil }
        XCTAssertTrue(phone.motionSelected)
        let (http, session, _) = try caller.embodimentSetupAccess()
        let path = "/inspection/v1/embodiments/" + body
        let leaseData = try await http.send(path + "/leases", sessionID: session, method: "POST", body: Data(#"{"channel":"orientation","fps":10}"#.utf8))
        let lease = try JSONValue.decode(leaseData).inspectionFields(required: ["lease_id","expires_at","fps"]).field("lease_id").string()
        let cameraData = try await http.send(path + "/leases", sessionID: session, method: "POST", body: Data(#"{"fps":3}"#.utf8))
        let cameraLease = try JSONValue.decode(cameraData).inspectionFields(required: ["lease_id","expires_at","fps"]).field("lease_id").string()
        let renewer = Task { @MainActor in
            while !Task.isCancelled {
                for (id, channel, fps) in [(lease, "orientation", 10), (cameraLease, "camera", 3)] {
                    let payload = JSONValue.object(["lease_id":.string(id),"channel":.string(channel),"fps":.integer(Int64(fps))])
                    _ = try? await http.send(path+"/leases", sessionID:session, method:"POST", body:JSONEncoder().encode(payload))
                }
                do { try await Task.sleep(for:.seconds(4)) } catch { return }
            }
        }
        defer { renewer.cancel() }
        var samples: [LocalMotionAttitude] = []
        let start = Date(), publications = phone.motion.published
        for _ in 0..<60 {
            if let sample = phone.motion.acquisition.latest, sample.sequence != samples.last?.sequence { samples.append(sample) }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(samples.count, 35)
        let residual = samples.map(\.gravityResidual).max() ?? 100
        XCTAssertLessThan(residual, 0.15)
        let rotationSpan = samples.map { 2 * acos(min(1, abs(simd_dot(samples[0].quaternion.vector, $0.quaternion.vector)))) }.max() ?? 100
        let rate = Double(phone.motion.published-publications)/Date().timeIntervalSince(start)
        XCTAssertLessThan(rotationSpan, 2 * .pi / 180, "Rest the iPhone stationary for the stability interval")
        XCTAssertGreaterThanOrEqual(rate, 5)
        XCTAssertLessThanOrEqual(rate, 10.1)
        print("MOTION STATIONARY samples=\(samples.count) span_degrees=\(rotationSpan * 180 / .pi) gravity_residual=\(residual) publication_hz=\(Double(phone.motion.published-publications)/Date().timeIntervalSince(start))")
        let loaded = try JSONValue.decode(await http.send(path + "/orientation?lease_id=" + lease, sessionID: session)).inspectionFields(required:["diagnostic","motion_enabled","canonical_orientation","runtime"])
        let diagnostic = try loaded.field("diagnostic").inspectionFields(required:["reference_frame_id","quaternion","household_aligned","measured_at"])
        XCTAssertEqual(try diagnostic.field("household_aligned"), .bool(false))
        XCTAssertEqual(try diagnostic.field("reference_frame_id").string(), phone.motion.acquisition.referenceID)
        let canonical = try loaded.field("canonical_orientation").inspectionFields(required:["state"])
        XCTAssertEqual(try canonical.field("state"), .string("UNAVAILABLE"))
        let preview = try JSONValue.decode(await http.send(path + "/frames?lease_id=" + cameraLease, sessionID: session)).inspectionFields(required:["frame","runtime"])
        XCTAssertNotEqual(try preview.field("frame"), .null)
        _ = try await http.send(path+"/leases", sessionID: session, method:"POST", body: JSONEncoder().encode(["lease_id":lease,"channel":"orientation"].mapValues(JSONValue.string).merging(["fps":.integer(10)]) { _, b in b }))
        let chat = try caller.conversationAccess()
        let conversation = try await chat.transport.selectOrCreate(sessionID: chat.sessionID)
        _ = try await chat.transport.setActive(id: conversation.id, embodimentID: body, sessionID: chat.sessionID)
        try await chat.transport.stream(id: conversation.id, content:"我是谁", sessionID:chat.sessionID) { _ in }
        let history = try await chat.transport.history(id:conversation.id, sessionID:chat.sessionID)
        XCTAssertFalse(history.messages.last?.content.isEmpty ?? true)
        let captures = phone.vision.captures
        try await chat.transport.stream(id:conversation.id, content:"你现在能看到什么？", sessionID:chat.sessionID) { _ in }
        XCTAssertGreaterThan(phone.vision.captures, captures)
        XCTAssertEqual(caller.displayedState, .connected); XCTAssertTrue(phone.isOnline)
        let oldReference = phone.motion.acquisition.referenceID
        phone.setForeground(false)
        XCTAssertNil(phone.motion.acquisition.latest)
        phone.setForeground(true)
        try await wait { phone.isOnline && phone.motion.acquisition.latest != nil }
        XCTAssertNotEqual(phone.motion.acquisition.referenceID, oldReference)
        let oldSession = phone.connection.session?.sessionID
        await phone.connection.disconnect(); phone.enableRuntime()
        try await wait { phone.isOnline && phone.connection.session?.sessionID != oldSession && phone.motion.acquisition.latest != nil }
        XCTAssertEqual(phone.embodimentID, body)
        XCTAssertNotEqual(phone.motion.acquisition.referenceID, oldReference)
        await phone.changeMotion(false, caller:caller)
        XCTAssertFalse(phone.motionSelected); XCTAssertNil(phone.motion.acquisition.latest)
        let count = phone.motion.published
        try await Task.sleep(for:.seconds(1))
        XCTAssertEqual(phone.motion.published, count)
        _ = try? await http.send(path + "/leases/" + lease, sessionID:session, method:"DELETE")
        _ = try? await http.send(path + "/leases/" + cameraLease, sessionID:session, method:"DELETE")
        if initiallyEnabled { await phone.changeMotion(true, caller:caller) }
        print("MOTION LIFECYCLE INSPECTOR CHAT CAMERA HEARTBEAT PASS")
        #endif
    }
    @MainActor func testPhysicalWiFiMotionRecovery() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires manual Wi-Fi interruption on the physical phone")
        #else
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        let caller = AppRuntime.connection, phone = AppRuntime.embodiment
        caller.setForeground(true); caller.connect(); phone.setForeground(true); phone.enableRuntime()
        try await wait { caller.displayedState == .connected && phone.isOnline }
        await phone.refreshConfiguration(caller:caller)
        let wasEnabled = phone.motionSelected
        await phone.changeMotion(true,caller:caller)
        try await wait { phone.isOnline && phone.motion.acquisition.latest != nil }
        let body = try XCTUnwrap(phone.embodimentID)
        let deviceSession = phone.connection.session?.sessionID
        let callerSession = caller.session?.sessionID
        let reference = phone.motion.acquisition.referenceID
        print("MOTION WIFI INTERRUPTION READY")
        try await wait(timeoutSeconds: 180) { phone.connection.session?.sessionID != deviceSession && caller.session?.sessionID != callerSession && phone.isOnline && caller.displayedState == .connected }
        try await wait { phone.motion.acquisition.latest != nil }
        XCTAssertEqual(phone.embodimentID,body)
        XCTAssertNotEqual(phone.motion.acquisition.referenceID,reference)
        let (http, session, _) = try caller.embodimentSetupAccess()
        let path = "/inspection/v1/embodiments/" + body
        let data = try await http.send(path+"/leases",sessionID:session,method:"POST",body:Data(#"{"channel":"orientation","fps":10}"#.utf8))
        let lease = try JSONValue.decode(data).inspectionFields(required:["lease_id"]).field("lease_id").string()
        let before = phone.motion.published
        try await wait { phone.motion.published > before }
        let fields = try JSONValue.decode(await http.send(path+"/orientation?lease_id="+lease,sessionID:session)).inspectionFields(required:["diagnostic"])
        let diagnostic = try fields.field("diagnostic").inspectionFields(required:["session_id","reference_frame_id","measured_at"])
        XCTAssertEqual(try diagnostic.field("session_id").string(),phone.connection.session?.sessionID)
        XCTAssertEqual(try diagnostic.field("reference_frame_id").string(),phone.motion.acquisition.referenceID)
        let measured = try V1Time.parse(diagnostic.field("measured_at").string())
        XCTAssertLessThan(Date().timeIntervalSince(measured),1)
        _ = try? await http.send(path+"/leases/"+lease,sessionID:session,method:"DELETE")
        if !wasEnabled { await phone.changeMotion(false,caller:caller) }
        print("MOTION WIFI RECOVERY PASS")
        #endif
    }

    /// Each trial starts a new initial-body reference; the operator performs the named +90° rotation.
    @MainActor private func rotationTrial(axis: SIMD3<Double>, name: String, angle: Double = .pi/2, toleranceDegrees: Double = 20) async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an operator rotating the physical phone")
        #else
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        let motion = MotionAcquisition()
        defer { motion.stop() }
        motion.start()
        for _ in 0..<30 { motion.poll(); try await Task.sleep(for:.milliseconds(100)) }
        let reference = try XCTUnwrap(motion.referenceID)
        print("MOTION ROTATION READY \(name) reference=\(reference)")
        let expected = simd_quatd(angle:angle, axis:axis)
        var heldFrames = 0
        var previous: simd_quatd?
        for _ in 0..<1800 {
            if let sample = motion.poll() {
                let error = 2 * acos(min(1, abs(simd_dot(expected.vector, sample.quaternion.vector))))
                let step = previous.map { 2 * acos(min(1, abs(simd_dot($0.vector, sample.quaternion.vector)))) } ?? .infinity
                heldFrames = error < toleranceDegrees * .pi / 180 && step < 2 * .pi / 180 ? heldFrames + 1 : 0
                previous = sample.quaternion
                if heldFrames >= 8 {
                    print("MOTION ROTATION PASS \(name) error_degrees=\(error*180 / .pi) quaternion=\(IPhoneBodyFrame.components(sample.quaternion)) angles=\(sample.angles)")
                    let eulerQ = IPhoneBodyFrame.quaternion(yaw:sample.angles.x,pitch:sample.angles.y,roll:sample.angles.z)
                    XCTAssertEqual(abs(simd_dot(sample.quaternion.vector,eulerQ.vector)),1,accuracy:1e-10)
                    return
                }
            }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTFail("No \(angle*180 / .pi) degree \(name) rotation observed within \(toleranceDegrees) degree tolerance; native status: \(motion.status)")
        #endif
    }
    @MainActor func testPhysicalYawPositive90() async throws { try await rotationTrial(axis:SIMD3(0,0,1),name:"yaw +Z") }
    @MainActor func testPhysicalPitchPositive90() async throws { try await rotationTrial(axis:SIMD3(0,1,0),name:"pitch +Y") }
    @MainActor func testPhysicalPitchNegative45() async throws { try await rotationTrial(axis:SIMD3(0,1,0),name:"pitch -Y",angle:-.pi/4,toleranceDegrees:15) }
    @MainActor func testPhysicalRollPositive90() async throws { try await rotationTrial(axis:SIMD3(1,0,0),name:"roll +X") }
    @MainActor func testPhysicalCombinedRotation() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an operator rotating the physical phone")
        #else
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        let motion = MotionAcquisition(); motion.start(); defer { motion.stop() }
        print("MOTION COMBINED READY")
        var sawMultipleAxes = false
        var observed: LocalMotionAttitude?
        for _ in 0..<600 {
            if let sample = motion.poll() {
                let q = IPhoneBodyFrame.quaternion(yaw:sample.angles.x,pitch:sample.angles.y,roll:sample.angles.z)
                XCTAssertEqual(abs(simd_dot(sample.quaternion.vector,q.vector)),1,accuracy:1e-10)
                if [sample.angles.x,sample.angles.y,sample.angles.z].filter({ abs($0) > .pi/6 }).count >= 2 { sawMultipleAxes = true; observed = sample; break }
            }
            try await Task.sleep(for:.milliseconds(100))
        }
        XCTAssertTrue(sawMultipleAxes,"No multi-axis physical rotation observed")
        if let observed { print("MOTION COMBINED PASS quaternion=\(IPhoneBodyFrame.components(observed.quaternion)) angles=\(observed.angles)") }
        #endif
    }

}

private extension JSONValue {
    /// Inspection is an application read API; only frozen V1 uses closed-object envelope decoding.
    func inspectionFields(required: Set<String>) throws -> [String: JSONValue] {
        guard case .object(let fields) = self, required.isSubset(of: Set(fields.keys)) else { throw ClientFailure.invalidResponse }
        return fields
    }
}
