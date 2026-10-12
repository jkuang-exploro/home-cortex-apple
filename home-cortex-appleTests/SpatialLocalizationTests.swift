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

final class VisualAnchorTests: XCTestCase {
    private let k = VisualIntrinsics(fx: 900, fy: 910, cx: 640, cy: 480)
    private func transform(_ p: SIMD3<Double>, _ a: SIMD3<Double> = .zero) throws -> RigidTransform {
        try RigidTransform(rotation: IPhoneBodyFrame.quaternion(yaw: a.x, pitch: a.y, roll: a.z), translation: p)
    }
    private func board(_ id: String, start: Int, pose: RigidTransform) throws -> [VisualTag] {
        try [SIMD3(-0.048,0.048,0.0), SIMD3(0.048,0.048,0.0), SIMD3(-0.048,-0.048,0.0), SIMD3(0.048,-0.048,0.0)]
            .enumerated().map { index, center in
                let tag = try pose.composed(with: transform(center, SIMD3(0,0,.pi)))
                let corners = [SIMD3(-0.024,0.024,0.0), SIMD3(0.024,0.024,0.0), SIMD3(0.024,-0.024,0.0), SIMD3(-0.024,-0.024,0.0)].map(tag.point)
                return VisualTag(id: start+index, boardID: id, edge: 0.048, spaceFromTag: tag,
                    corners: corners, boardCenter: pose.translation, boardNormal: pose.rotation.act(SIMD3(0,0,1)))
            }
    }
    private func detections(_ tags: [VisualTag], camera: RigidTransform, noise: Double = 0) throws -> [VisualDetection] {
        let cameraFromSpace = try camera.inverse
        return try tags.map { tag in
            let corners = tag.corners.enumerated().map { i, p -> SIMD2<Double> in
                let shift = noise * (tag.id < 4 ? 1 : -1)
                return k.project(cameraFromSpace.point(p))! + SIMD2(shift, shift*0.6 + Double(i%2)*noise*0.1)
            }
            return VisualDetection(id: tag.id, corners: corners,
                cameraFromTag: try cameraFromSpace.composed(with: tag.spaceFromTag), alternative: nil)
        }
    }
    private func assertPose(_ a: RigidTransform, _ b: RigidTransform, tolerance: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_distance(a.translation,b.translation), tolerance, file:file,line:line)
        XCTAssertGreaterThan(abs(simd_dot(a.rotation.vector,b.rotation.vector)),1-tolerance, file:file,line:line)
    }
    func testSingleWallAnchorRecoversAllSixDOFWithoutFlatPlacement() throws {
        let wall = try transform(SIMD3(1,2,0.9), SIMD3(0,0,.pi/2))
        let tags = try board("board_a", start:0, pose:wall)
        let camera = try wall.composed(with: transform(SIMD3(0.03,-0.04,0.6), SIMD3(0.18,0.15,.pi-0.1)))
        let solution = try VisualPoseSolver.solve(tags:tags, detections:detections(tags,camera:camera), intrinsics:k)
        assertPose(solution.spaceFromOpticalCamera,camera)
        XCTAssertEqual(solution.boardIDs,["board_a"])
        XCTAssertEqual(solution.tagCount,4)
        XCTAssertLessThan(solution.rmse,1e-6)
        // Partial occlusion: a single unambiguous tag is also geometrically sufficient.
        let partial = try VisualPoseSolver.solve(tags:tags, detections:Array(detections(tags,camera:camera).prefix(1)), intrinsics:k)
        assertPose(partial.spaceFromOpticalCamera,camera)
    }
    func testJointMultipleBoardFitReducesSyntheticCornerNoise() throws {
        let wall = try transform(SIMD3(1,2,0.9), SIMD3(0,0,.pi/2))
        let a = try board("board_a", start:0, pose:wall)
        let b = try board("board_b", start:4, pose:wall.composed(with:transform(SIMD3(0.25,0,0))))
        let camera = try wall.composed(with:transform(SIMD3(0.12,-0.03,0.8),SIMD3(0.1,0.12,.pi-0.05)))
        let one = try VisualPoseSolver.solve(tags:a, detections:detections(a,camera:camera,noise:0.4), intrinsics:k)
        let combined = try VisualPoseSolver.solve(tags:a+b, detections:detections(a+b,camera:camera,noise:0.4), intrinsics:k)
        XCTAssertEqual(combined.boardIDs,["board_a","board_b"])
        XCTAssertEqual(combined.tagCount,8)
        XCTAssertLessThan(simd_distance(combined.spaceFromOpticalCamera.translation,camera.translation),simd_distance(one.spaceFromOpticalCamera.translation,camera.translation))
    }
    func testUnknownDuplicateAndMisplacedObservationsDoNotBiasPose() throws {
        let wall = try transform(SIMD3(1,2,0.9), SIMD3(0,0,.pi/2))
        let tags = try board("board_a",start:0,pose:wall)
        let camera = try wall.composed(with:transform(SIMD3(0,-0.03,0.6),SIMD3(0.1,0.1,.pi-0.1)))
        let good = try detections(tags,camera:camera)
        let outlier = VisualDetection(id:3,corners:good[3].corners.map { $0+SIMD2(200,180) },cameraFromTag:good[3].cameraFromTag,alternative:nil)
        let result = try VisualPoseSolver.solve(tags:tags,detections:Array(good.prefix(3))+[outlier],intrinsics:k)
        assertPose(result.spaceFromOpticalCamera,camera)
        XCTAssertEqual(result.tagCount,3)
        XCTAssertThrowsError(try VisualPoseSolver.solve(tags:tags,detections:[good[0],good[0]],intrinsics:k))
        XCTAssertThrowsError(try VisualPoseSolver.solve(tags:[],detections:good,intrinsics:k))
    }
    func testARKitOpticalFrameConversionAtNontrivialPose() throws {
        let camera = try transform(SIMD3(1.2,2.1,0.7),SIMD3(0.4,-0.2,0.1))
        let truth = try transform(SIMD3(-2,1,3),SIMD3(-0.7,0.3,-0.1))
        let worldFromAR = try truth.inverse.composed(with:camera).composed(with:.opticalFromARCamera)
        let frame = VisualFrame(pixels:Data(),width:1,height:1,stride:1,intrinsics:k,worldFromARCamera:worldFromAR,worldID:"world:one",measuredAt:Date())
        let solution = VisualSolution(spaceFromOpticalCamera:camera,boardIDs:["board_a"],tagCount:4,rmse:0.1)
        let sample = try VisualAlignmentSample(solution:solution,frame:frame)
        assertPose(sample.spaceFromWorld,truth)
    }
    @MainActor func testCameraAlignmentTracksMotionAndInvalidatesOnEpochChange() throws {
        let raw: [String:Any] = ["space_id":"space:test","frame_id":"frame_test","manifest_sha256":String(repeating:"a",count:64),"units":"meters",
            "boards":[["board_id":"board_a","installation_status":"planned_unsurveyed","T_world_from_board":[[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]],
                "fiducials":[["family":"tag36h11","tag_id":0,"detection_edge_m":0.048,"T_world_from_apriltag":[[1,0,0,0],[0,-1,0,0],[0,0,-1,0],[0,0,0,1]],
                    "detection_corners_world_m":[[-0.024,-0.024,0],[0.024,-0.024,0],[0.024,0.024,0],[-0.024,0.024,0]]]]]]]
        let catalog = try JSONDecoder().decode(VisualAnchorCatalog.self,from:JSONSerialization.data(withJSONObject:raw))
        let state = VisualAnchorCalibration()
        try state.begin(catalog:catalog,selectedBoards:["board_a"],deviceSession:"session:one")
        let truth = try transform(SIMD3(2,3,1),SIMD3(0.1,0.3,-0.2))
        let now = Date()
        for i in 0..<3 {
            let camera = try transform(SIMD3(Double(i)*0.1,0,0.6),SIMD3(0.2,0.1,.pi-0.1))
            let frame = VisualFrame(pixels:Data(),width:1,height:1,stride:1,intrinsics:k,
                worldFromARCamera:try truth.inverse.composed(with:camera).composed(with:.opticalFromARCamera),worldID:"world:one",measuredAt:now.addingTimeInterval(-0.6+Double(i)*0.3))
            try state.receive(solution:VisualSolution(spaceFromOpticalCamera:camera,boardIDs:["board_a"],tagCount:1,rmse:0.3),frame:frame,session:"session:one",now:now)
        }
        XCTAssertTrue(state.aligned)
        assertPose(try XCTUnwrap(state.spaceFromWorld),truth)
        state.detectionFailed(VisualAnchorError.noAnchor)
        XCTAssertTrue(state.aligned)
        let moved = try transform(SIMD3(1,2,0.7),SIMD3(0.5,0.2,0.1))
        let movedInWorld = try truth.inverse.composed(with:moved).composed(with:.opticalFromARCamera)
        state.update(worldID:"world:one",session:"session:one",camera:movedInWorld,healthy:true,measuredAt:Date())
        assertPose(try XCTUnwrap(state.cameraPose),moved)
        state.update(worldID:"world:two",session:"session:one",camera:movedInWorld,healthy:true,measuredAt:Date())
        XCTAssertFalse(state.aligned)
        XCTAssertNil(state.cameraPose)
    }
    func testRealDetectorOnSyntheticTagPixelsUsesRawIntrinsics() async throws {
        // Authentic tag36h11 ID0. Synthetic image; no physical accuracy claim.
        let rows = ["0000000000","0111111110","0100101010","0110001010","0110011110","0101011110","0110100110","0111101110","0111111110","0000000000"]
        // Use the official code cells below; each cell is 10 px, detection edge is 80 px.
        var pixels = [UInt8](repeating:255,count:640*480)
        for y in 0..<100 { for x in 0..<100 {
            let cells = Array(rows[y/10]); pixels[(190+y)*640+270+x] = cells[x/10] == "1" ? 0 : 255
        } }
        let wall = try transform(.zero)
        let tags = try board("board_a",start:0,pose:wall)
        // This test's tag is centered at board origin, independent of the board fixture offsets.
        let tagPose = try transform(.zero,SIMD3(0,0,.pi))
        let tag = VisualTag(id:0,boardID:"board_a",edge:0.048,spaceFromTag:tagPose,
            corners:[SIMD3(-0.024,0.024,0),SIMD3(0.024,0.024,0),SIMD3(0.024,-0.024,0),SIMD3(-0.024,-0.024,0)].map(tagPose.point),boardCenter:.zero,boardNormal:SIMD3(0,0,1))
        XCTAssertEqual(tags.count,4)
        let frame = VisualFrame(pixels:Data(pixels),width:640,height:480,stride:640,
            intrinsics:VisualIntrinsics(fx:800,fy:800,cx:320,cy:240),worldFromARCamera:try transform(.zero),worldID:"world:test",measuredAt:Date())
        let result = try await VisualAnchorDetector().solve(frame:frame,tags:[tag])
        XCTAssertEqual(result.tagCount,1)
        XCTAssertEqual(result.spaceFromOpticalCamera.translation.z,0.48,accuracy:0.02)
    }

    func testRealDetectorRecoversTiltedWallBoardFromPerspectivePixels() async throws {
        let bitmaps = [["0000000000","0111111110","0100101010","0110001010","0110011110","0101011110","0110100110","0111101110","0111111110","0000000000"],["0000000000","0111111110","0100100110","0110100010","0100001110","0110011110","0101001010","0111011010","0111111110","0000000000"],["0000000000","0111111110","0100100010","0110110110","0101111110","0111011010","0111101110","0111000110","0111111110","0000000000"],["0000000000","0111111110","0100011010","0111100010","0101100010","0101011010","0100110110","0110011110","0111111110","0000000000"]]
        let wall = try transform(SIMD3(1,2,0.9),SIMD3(0,0,.pi/2))
        let tags = try board("board_a",start:0,pose:wall)
        // All translation and orientation components differ from the reference;
        // large in-image rotation exercises unrotated pixel/intrinsic mapping.
        let orientation = IPhoneBodyFrame.quaternion(yaw:0.7,pitch:0.25,roll:.pi-0.2)
        let camera = try wall.composed(with:RigidTransform(rotation:orientation,translation:orientation.act(SIMD3(0,0,-0.65))))
        let intrinsics = VisualIntrinsics(fx:800,fy:810,cx:320,cy:240)
        let transforms = try tags.map { try $0.spaceFromTag.inverse.composed(with:camera) }
        var pixels = [UInt8](repeating:255,count:640*480)
        for y in 0..<480 { for x in 0..<640 {
            let ray = SIMD3((Double(x)+0.5-intrinsics.cx)/intrinsics.fx,(Double(y)+0.5-intrinsics.cy)/intrinsics.fy,1)
            for i in tags.indices {
                let t = transforms[i], direction = t.rotation.act(ray)
                guard abs(direction.z) > 1e-8 else { continue }
                let distance = -t.translation.z/direction.z
                guard distance > 0 else { continue }
                let p = t.translation + distance*direction
                let col = Int(floor((p.x+0.03)/0.006)), row = Int(floor((p.y+0.03)/0.006))
                if (0..<10).contains(col), (0..<10).contains(row) {
                    pixels[y*640+x] = Array(bitmaps[i][row])[col] == "1" ? 0 : 255
                }
            }
        } }
        let frame = VisualFrame(pixels:Data(pixels),width:640,height:480,stride:640,intrinsics:intrinsics,
            worldFromARCamera:try transform(.zero),worldID:"world:test",measuredAt:Date())
        let detector = VisualAnchorDetector()
        let observed = try await detector.detections(frame:frame,tags:tags)
        XCTAssertEqual(observed.map(\.id).sorted(),[0,1,2,3])
        let result = try await detector.solve(frame:frame,tags:tags)
        XCTAssertEqual(result.boardIDs,["board_a"])
        XCTAssertEqual(result.tagCount,4)
        XCTAssertLessThan(simd_distance(result.spaceFromOpticalCamera.translation,camera.translation),0.02)
        XCTAssertGreaterThan(abs(simd_dot(result.spaceFromOpticalCamera.rotation.vector,camera.rotation.vector)),0.999)
        XCTAssertLessThan(result.rmse,1)
    }

    private func feedbackCatalog() -> VisualAnchorCatalog {
        let boards = ["board_a", "board_b"].enumerated().map { i, id in
            let x = Double(i)
            return VisualAnchorCatalog.Board(board_id:id,installation_status:"planned_unsurveyed",
                T_world_from_board:[[1,0,0,x],[0,1,0,0],[0,0,1,0],[0,0,0,1]],fiducials:[
                    VisualAnchorCatalog.Tag(family:"tag36h11",tag_id:i*4,detection_edge_m:0.048,
                        T_world_from_apriltag:[[1,0,0,x],[0,-1,0,0],[0,0,-1,0],[0,0,0,1]],
                        detection_corners_world_m:[[x-0.024,-0.024,0],[x+0.024,-0.024,0],[x+0.024,0.024,0],[x-0.024,0.024,0]])])
        }
        return VisualAnchorCatalog(space_id:"space:test",frame_id:"frame_test",manifest_sha256:String(repeating:"a",count:64),units:"meters",boards:boards)
    }
    @MainActor private func feed(_ state: VisualAnchorCalibration, boards: [String], alignment: RigidTransform,
                                seconds: Double, disagreements: [VisualAnchorDisagreement] = []) throws {
        let time = Date(timeIntervalSince1970:1000+seconds)
        let frame = VisualFrame(pixels:Data(),width:1,height:1,stride:1,intrinsics:k,
            worldFromARCamera:try transform(.zero),worldID:"world:one",measuredAt:time)
        let solution = VisualSolution(spaceFromOpticalCamera:try alignment.composed(with:.opticalFromARCamera),
            boardIDs:boards,tagCount:boards.count,rmse:0.3,disagreements:disagreements)
        try state.receive(solution:solution,frame:frame,session:"session:one",now:time)
    }
    @MainActor func testCompletionNotificationRequiresThreeObservationsForEachAnchor() throws {
        let state = VisualAnchorCalibration()
        try state.begin(catalog:feedbackCatalog(),selectedBoards:["board_a","board_b"],deviceSession:"session:one")
        let alignment = try transform(.zero)
        try feed(state,boards:["board_a"],alignment:alignment,seconds:0)
        try feed(state,boards:["board_a"],alignment:alignment,seconds:0.3)
        XCTAssertNil(state.completionNotice)
        try feed(state,boards:["board_a","board_b"],alignment:alignment,seconds:0.6)
        XCTAssertEqual(state.completedBoardIDs,["board_a"])
        XCTAssertEqual(state.completionNotice,"Calibration finished: board_a")
        XCTAssertEqual(state.completionSequence,1)
        try feed(state,boards:["board_b"],alignment:alignment,seconds:0.9)
        XCTAssertEqual(state.completedBoardIDs,["board_a"])
        try feed(state,boards:["board_b"],alignment:alignment,seconds:1.2)
        XCTAssertEqual(state.completedBoardIDs,["board_a","board_b"])
        XCTAssertEqual(state.completionNotice,"Calibration finished: board_b")
        XCTAssertEqual(state.completionSequence,2)
        for i in 0..<3 { try feed(state,boards:["board_a"],alignment:alignment,seconds:20+Double(i)*0.3) }
        XCTAssertEqual(state.completionSequence,2)
        XCTAssertEqual(state.completedBoardIDs,["board_a","board_b"])
    }
    @MainActor func testSustainedConflictAfterOldSamplesExpireAllowsKeepOrEraseAndChoose() throws {
        let state = VisualAnchorCalibration(), catalog = feedbackCatalog()
        try state.begin(catalog:catalog,selectedBoards:["board_a","board_b"],deviceSession:"session:one")
        let old = try transform(.zero), different = try transform(SIMD3(0.4,0,0))
        for i in 0..<3 { try feed(state,boards:["board_a"],alignment:old,seconds:Double(i)*0.3) }
        let retained = try XCTUnwrap(state.spaceFromWorld)
        try feed(state,boards:["board_b"],alignment:different,seconds:20)
        XCTAssertNil(state.pendingConflict)
        XCTAssertEqual(state.completedBoardIDs,["board_a"])
        try feed(state,boards:["board_b"],alignment:different,seconds:20.3)
        try feed(state,boards:["board_b"],alignment:different,seconds:20.6)
        let conflict = try XCTUnwrap(state.pendingConflict)
        XCTAssertEqual(conflict.previousBoardIDs,["board_a"])
        XCTAssertEqual(conflict.proposedBoardIDs,["board_b"])
        XCTAssertEqual(conflict.choices,["board_a","board_b"])
        XCTAssertEqual(conflict.distanceMeters,0.4,accuracy:1e-8)
        assertPose(try XCTUnwrap(state.spaceFromWorld),retained)
        XCTAssertFalse(state.needsVisualObservations)
        XCTAssertThrowsError(try state.eraseAndRecalibrate(using:"unknown"))
        assertPose(try XCTUnwrap(state.spaceFromWorld),retained)
        state.keepCurrentCalibration()
        XCTAssertNil(state.pendingConflict)
        XCTAssertEqual(state.ignoredBoardIDs,["board_b"])
        XCTAssertEqual(state.activeBoardIDs,["board_a"])
        XCTAssertTrue(state.needsVisualObservations)
        assertPose(try XCTUnwrap(state.spaceFromWorld),retained)
        // Explicit restart gives both installed boards another chance; erase can
        // then select just the conflicting board without replacing room geometry.
        try state.begin(catalog:catalog,selectedBoards:["board_a","board_b"],deviceSession:"session:one")
        for i in 0..<3 { try feed(state,boards:["board_a"],alignment:old,seconds:30+Double(i)*0.3) }
        for i in 0..<3 { try feed(state,boards:["board_b"],alignment:different,seconds:31+Double(i)*0.3) }
        let generation = state.generation
        try state.eraseAndRecalibrate(using:"board_b")
        XCTAssertGreaterThan(state.generation,generation)
        XCTAssertNil(state.spaceFromWorld)
        XCTAssertNil(state.cameraPose)
        XCTAssertNil(state.pendingConflict)
        XCTAssertEqual(state.completedBoardIDs,[])
        XCTAssertEqual(state.activeBoardIDs,["board_b"])
        XCTAssertEqual(state.catalog?.manifest_sha256,catalog.manifest_sha256)
        for i in 0..<3 { try feed(state,boards:["board_b"],alignment:different,seconds:32+Double(i)*0.3) }
        assertPose(try XCTUnwrap(state.spaceFromWorld),different)
        XCTAssertEqual(state.completedBoardIDs,["board_b"])
        XCTAssertEqual(state.completionNotice,"Calibration finished: board_b")
    }
    @MainActor func testTransientAndAngularConflictDoNotSilentlyReplaceCalibration() throws {
        let state = VisualAnchorCalibration()
        try state.begin(catalog:feedbackCatalog(),selectedBoards:["board_a","board_b"],deviceSession:"session:one")
        let old = try transform(.zero), rotated = try transform(.zero,SIMD3(0.4,0,0))
        for i in 0..<3 { try feed(state,boards:["board_a"],alignment:old,seconds:Double(i)*0.3) }
        try feed(state,boards:["board_b"],alignment:rotated,seconds:1)
        try feed(state,boards:["board_a"],alignment:old,seconds:1.3)
        XCTAssertNil(state.pendingConflict)
        for i in 0..<3 { try feed(state,boards:["board_b"],alignment:rotated,seconds:2+Double(i)*0.3) }
        let conflict = try XCTUnwrap(state.pendingConflict)
        XCTAssertEqual(conflict.distanceMeters,0,accuracy:1e-8)
        XCTAssertEqual(conflict.angleRadians,0.4,accuracy:1e-8)
        assertPose(try XCTUnwrap(state.spaceFromWorld),old)
        state.invalidate("Tracking restarted")
        XCTAssertNil(state.pendingConflict)
        XCTAssertEqual(state.completedBoardIDs,[])
    }
    func testCoherentConflictingBoardCannotBeHiddenByOutlierRejection() throws {
        let wall = try transform(SIMD3(1,2,0.9),SIMD3(0,0,.pi/2))
        let a = try board("board_a",start:0,pose:wall)
        let actualB = try board("board_b",start:4,pose:wall.composed(with:transform(SIMD3(0.25,0,0))))
        let wronglySurveyedB = try board("board_b",start:4,pose:wall.composed(with:transform(SIMD3(0.65,0,0))))
        let camera = try wall.composed(with:transform(SIMD3(0.12,-0.03,0.8),SIMD3(0.1,0.12,.pi-0.05)))
        let observed = try detections(a+actualB,camera:camera)
        let result = try VisualPoseSolver.solve(tags:a+wronglySurveyedB,detections:observed,intrinsics:k)
        XCTAssertEqual(result.disagreements.count,1)
        XCTAssertEqual(result.disagreements[0].distanceMeters,0.4,accuracy:1e-5)
        XCTAssertEqual(Set(result.boardIDs+result.disagreements.map(\.boardID)),["board_a","board_b"])
    }
    @MainActor func testSimultaneousBoardConflictPausesBeforeAnyCompletion() throws {
        let state = VisualAnchorCalibration()
        try state.begin(catalog:feedbackCatalog(),selectedBoards:["board_a","board_b"],deviceSession:"session:one")
        let conflict = VisualAnchorDisagreement(boardID:"board_b",distanceMeters:0.4,angleRadians:0)
        for i in 0..<3 { try feed(state,boards:["board_a"],alignment:transform(.zero),seconds:Double(i)*0.3,disagreements:[conflict]) }
        XCTAssertNotNil(state.pendingConflict)
        XCTAssertEqual(state.completedBoardIDs,[])
        XCTAssertFalse(state.aligned)
        try state.eraseAndRecalibrate(using:"board_b")
        XCTAssertTrue(state.needsVisualObservations)
        XCTAssertEqual(state.activeBoardIDs,["board_b"])
    }

    @MainActor func testAlternatingFitWinnerStillPromptsForSimultaneousConflict() throws {
        let state = VisualAnchorCalibration()
        try state.begin(catalog:feedbackCatalog(),selectedBoards:["board_a","board_b"],deviceSession:"session:one")
        for i in 0..<3 {
            let winner = i%2 == 0 ? "board_a" : "board_b"
            let other = i%2 == 0 ? "board_b" : "board_a"
            let alignment = try transform(SIMD3(i%2 == 0 ? 0 : 0.4,0,0))
            try feed(state,boards:[winner],alignment:alignment,seconds:Double(i)*0.3,
                disagreements:[VisualAnchorDisagreement(boardID:other,distanceMeters:0.4,angleRadians:0)])
        }
        let conflict = try XCTUnwrap(state.pendingConflict)
        XCTAssertEqual(conflict.choices,["board_a","board_b"])
        XCTAssertFalse(state.aligned)
        XCTAssertEqual(state.completedBoardIDs,[])
    }

    func testPartiallyAcceptedConflictingBoardStillSurfacesItsIndependentPose() throws {
        let wall = try transform(SIMD3(1,2,0.9),SIMD3(0,0,.pi/2))
        let a = try board("board_a",start:0,pose:wall)
        let actualPose = try wall.composed(with:transform(SIMD3(0.25,0,0)))
        let actualB = try board("board_b",start:4,pose:actualPose)
        let pivot = SIMD3(-0.048,0.048,0.0)
        let wrongPose = try actualPose.composed(with:transform(pivot))
            .composed(with:transform(.zero,SIMD3(0.25,0,0))).composed(with:transform(-pivot))
        let b = try board("board_b",start:4,pose:wrongPose)
        let camera = try wall.composed(with:transform(SIMD3(0.12,-0.03,2.4),SIMD3(0.05,0.05,.pi-0.02)))
        let result = try VisualPoseSolver.solve(tags:a+b,detections:detections(a+actualB,camera:camera),intrinsics:k)
        XCTAssertTrue(result.boardIDs.contains("board_b"))
        XCTAssertTrue(result.disagreements.contains { $0.boardID == "board_b" && $0.angleRadians > 12 * .pi/180 })
    }
}
