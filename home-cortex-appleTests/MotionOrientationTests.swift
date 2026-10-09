import XCTest
import simd
@testable import HomeCortex

final class MotionOrientationTests: XCTestCase {
    func testBodyBasisIsRightHandedAndConversionComposesOnRight() {
        let q = IPhoneBodyFrame.appleFromBody
        XCTAssertLessThan(simd_length(q.act(SIMD3(1,0,0)) - SIMD3(0,0,1)), 1e-12)
        XCTAssertLessThan(simd_length(q.act(SIMD3(0,1,0)) - SIMD3(1,0,0)), 1e-12)
        XCTAssertLessThan(simd_length(q.act(SIMD3(0,0,1)) - SIMD3(0,1,0)), 1e-12)
        XCTAssertLessThan(simd_length(simd_cross(q.act(SIMD3(1,0,0)), q.act(SIMD3(0,1,0))) - q.act(SIMD3(0,0,1))), 1e-12)
        let native = simd_quatd(angle: 0.7, axis: simd_normalize(SIMD3(1,2,3)))
        let body = IPhoneBodyFrame.nativeFromBody(native)
        XCTAssertLessThan(simd_length(body.act(SIMD3(0,0,1)) - native.act(SIMD3(0,1,0))), 1e-12)
    }
    func testPartialCameraGeometryDoesNotInventExtrinsic() {
        let q = IPhoneRearCameraGeometry.nominalBodyFromARKitCamera
        XCTAssertLessThan(simd_length(q.act(SIMD3(1,0,0)) - SIMD3(0,0,-1)), 1e-12)
        XCTAssertLessThan(simd_length(q.act(SIMD3(0,1,0)) - SIMD3(0,1,0)), 1e-12)
        XCTAssertLessThan(simd_length(q.act(SIMD3(0,0,-1)) - IPhoneRearCameraGeometry.nominalViewingDirectionBody), 1e-12)
        XCTAssertNil(IPhoneRearCameraGeometry.opticalCenterBodyMeters)
        XCTAssertNil(IPhoneRearCameraGeometry.calibratedBodyFromOptical)
    }
    func testRelativeReferenceRemovesInitialAttitudeAndAllThreeAxisSigns() {
        let initial = IPhoneBodyFrame.quaternion(yaw: 0.4, pitch: -0.3, roll: 0.2)
        for axis in 0..<3 {
            for sign in [-1.0, 1.0] {
                var angles = SIMD3<Double>(repeating: 0); angles[axis] = sign * .pi / 3
                let delta = IPhoneBodyFrame.quaternion(yaw: angles.x, pitch: angles.y, roll: angles.z)
                let relative = IPhoneBodyFrame.relative(initial: initial, current: initial * delta)
                XCTAssertLessThan(simd_length(IPhoneBodyFrame.euler(relative) - angles), 1e-12)
            }
        }
        XCTAssertLessThan(simd_length(IPhoneBodyFrame.relative(initial: initial, current: initial).imag), 1e-12)
    }
    func testCombinedRotationEulerQuaternionRoundTripAndComponentOrdering() {
        for yaw in [-2.0, 0.0, 1.5] {
            let q = IPhoneBodyFrame.quaternion(yaw: yaw, pitch: 0.6, roll: -0.8)
            let angles = IPhoneBodyFrame.euler(q)
            let reconstructed = IPhoneBodyFrame.quaternion(yaw: angles.x, pitch: angles.y, roll: angles.z)
            XCTAssertEqual(abs(simd_dot(q.vector, reconstructed.vector)), 1, accuracy: 1e-12)
            XCTAssertEqual(IPhoneBodyFrame.components(q), [q.imag.x,q.imag.y,q.imag.z,q.real])
        }
    }
    @MainActor func testReferenceResetsAndOffClearsLatest() throws {
        let motion = MotionAcquisition()
        guard motion.available else { throw XCTSkip("No Core Motion on this simulator") }
        motion.start(); let first = try XCTUnwrap(motion.referenceID)
        motion.start(); XCTAssertNotEqual(first, motion.referenceID)
        motion.stop(); XCTAssertNil(motion.referenceID); XCTAssertNil(motion.latest); XCTAssertEqual(motion.status, "Off")
    }
    func testDiagnosticsNeverClaimSpaceOrP95AndSelectionsRemainSeparate() throws {
        let sample = LocalMotionAttitude(referenceID: "motion:" + UUID().uuidString.lowercased(), sequence: 1,
            measuredAt: Date(), quaternion: simd_quatd(), nativeBodyQuaternion: simd_quatd(), gravityResidual: 0)
        let data = try JSONEncoder().encode(sample.diagnostic(body: "embodiment:test"))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(fields["household_aligned"] as? Bool, false)
        XCTAssertEqual(fields["uncertainty"] as? String, "unknown")
        XCTAssertNil(fields["space_id"]); XCTAssertNil(fields["p95"])
        let attempt = EmbodimentSetupAttempt(agentID: "agent:butler", camera: false, motion: true,
            clientID: "client:test", origin: URL(string: "https://example.test")!)
        XCTAssertEqual(attempt.capabilities, [])
        XCTAssertEqual(attempt.diagnostics, ["orientation.local"])
        XCTAssertEqual(try JSONDecoder().decode(EmbodimentSetupAttempt.self, from: JSONEncoder().encode(attempt)), attempt)
    }
}
