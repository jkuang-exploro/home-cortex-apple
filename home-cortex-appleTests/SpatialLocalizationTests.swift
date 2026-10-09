import XCTest
import simd
@testable import HomeCortex

final class SpatialLocalizationTests: XCTestCase {
    private func transform(_ translation: SIMD3<Double>, _ angles: SIMD3<Double> = .zero) throws -> RigidTransform {
        try RigidTransform(rotation: IPhoneBodyFrame.quaternion(yaw: angles.x, pitch: angles.y, roll: angles.z), translation: translation)
    }
    private func assertSame(_ a: RigidTransform, _ b: RigidTransform, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a.translation-b.translation), 1e-10, file: file, line: line)
        XCTAssertEqual(abs(simd_dot(a.rotation.vector,b.rotation.vector)),1,accuracy:1e-10,file:file,line:line)
    }
    func testInverseAndNoncommutingComposition() throws {
        let a = try transform(SIMD3(1,2,3),SIMD3(.pi/2,.pi/4,-.pi/3)), b = try transform(SIMD3(-4,5,6),SIMD3(-.pi/3,.pi/8,.pi/6))
        assertSame(try a.composed(with:b).composed(with:b.inverse),a)
        assertSame(try a.composed(with:a.inverse),try transform(.zero))
        XCTAssertGreaterThan(simd_length(try a.composed(with:b).translation-b.composed(with:a).translation),1)
    }
    func testCalibrationAndExtrinsicLeverArm() throws {
        let extrinsic = try transform(SIMD3(-0.004,0.02,0.06),SIMD3(0,.pi/2,0))
        let reference = try transform(SIMD3(2,3,1),SIMD3(.pi/3,0,0))
        let alignmentTruth = try transform(SIMD3(4,-2,1),SIMD3(.pi/4,-.pi/2,0))
        let cameraAtReference = try alignmentTruth.inverse.composed(with:reference).composed(with:extrinsic)
        let alignment = try HouseholdAlignment(worldID:"world:1",deviceSession:"session:1",spaceID:"space:test",referenceID:"dock",revision:1,
            referenceBodyInSpace:reference,referenceCameraInWorld:cameraAtReference,bodyFromCamera:extrinsic)
        assertSame(alignment.spaceFromWorld,alignmentTruth)
        assertSame(try alignment.bodyPose(cameraInWorld:cameraAtReference,bodyFromCamera:extrinsic),reference)
        let rotatedBody = try transform(reference.translation,SIMD3(.pi,0,.pi/4))
        let rotatedCamera = try alignmentTruth.inverse.composed(with:rotatedBody).composed(with:extrinsic)
        assertSame(try alignment.bodyPose(cameraInWorld:rotatedCamera,bodyFromCamera:extrinsic),rotatedBody)
        XCTAssertThrowsError(try HouseholdAlignment(worldID:"world:1",deviceSession:"session:1",spaceID:"space:test",referenceID:"dock",revision:1,
            referenceBodyInSpace:reference,referenceCameraInWorld:cameraAtReference,bodyFromCamera:nil))
    }
    func testInvalidMatrixAndUnknownUncertaintyRejected() throws {
        var reflected = matrix_identity_float4x4; reflected.columns.0.x = -1
        XCTAssertThrowsError(try RigidTransform(matrix:reflected))
        var scaled = matrix_identity_float4x4; scaled.columns.1.y = 2
        XCTAssertThrowsError(try RigidTransform(matrix:scaled))
        var skewed = matrix_identity_float4x4; skewed.columns.1.x = 0.1
        XCTAssertThrowsError(try RigidTransform(matrix:skewed))
        XCTAssertThrowsError(try PoseUncertaintyEnvelope(approvedRevision:"",p95:[Double](repeating:0.1,count:6),maxSeconds:10,maxPathMeters:2,maxRadiusMeters:1,maxAbsPitch:1))
        XCTAssertThrowsError(try PoseUncertaintyEnvelope(approvedRevision:"synthetic-test",p95:[.nan,0,0,0,0,0],maxSeconds:10,maxPathMeters:2,maxRadiusMeters:1,maxAbsPitch:1))
    }
    func testValidatedEnvelopeLimitsAndCanonicalEncoding() throws {
        // Synthetic bounds only test encoding/gates; this is not a production profile.
        let envelope = try PoseUncertaintyEnvelope(approvedRevision:"synthetic-test",p95:[0.2,0.3,0.4,0.1,0.1,0.1],maxSeconds:10,maxPathMeters:2,maxRadiusMeters:1,maxAbsPitch:1)
        XCTAssertTrue(envelope.permits(seconds:10,path:2,radius:1,pitch:1))
        for values in [[11.0,1,1,0],[1,3,1,0],[1,1,2,0],[1,1,1,1.5],[-1,1,1,0],[1,1,1,Double.nan]] {
            XCTAssertFalse(envelope.permits(seconds:values[0],path:values[1],radius:values[2],pitch:values[3]))
        }
        let measured = Date(timeIntervalSince1970:1000)
        let value = try CanonicalPoseEncoding.value(body:"embodiment:test",space:"space:test",measuredAt:measured,
            pose:transform(SIMD3(1,2,3),SIMD3(0.4,0.2,0.1)),uncertainty:envelope).object(required:["embodiment_id","space_id","measured_at","validity","transform"])
        XCTAssertEqual(value["measured_at"],.string(V1Time.format(measured)))
        let fields = try value.field("transform").object(required:["x","y","z","yaw","pitch","roll"])
        XCTAssertEqual(try fields.field("x").object(required:["value","p95"])["p95"],.number(0.2))
        XCTAssertEqual(try fields.field("y").object(required:["value","p95"])["value"],.number(2))
    }
}
