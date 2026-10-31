import XCTest
import UIKit
import Darwin
import simd
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import HomeCortex

private func patternedImage() -> CGImage {
    let ctx = CGContext(data: nil,width: 200,height: 300,bitsPerComponent: 8,bytesPerRow: 800,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1,green: 0,blue: 0,alpha: 1)); ctx.fill(CGRect(x: 0,y: 150,width: 200,height: 150))
    ctx.setFillColor(CGColor(red: 0,green: 0,blue: 1,alpha: 1)); ctx.fill(CGRect(x: 0,y: 0,width: 200,height: 150))
    ctx.setFillColor(CGColor(gray: 1,alpha: 1))
    for y in stride(from: 0,to: 300,by: 10) { for x in stride(from: 0,to: 200,by: 10) where (x+y)%20 == 0 { ctx.fill(CGRect(x: x,y: y,width: 4,height: 4)) } }
    return ctx.makeImage()!
}
@MainActor private final class ObservationTestCamera: ObservationAcquiring {
    var failure = false
    var frames = 0
    func observationFrame(body: String) async throws -> ObservationFrame {
        if failure { throw VisionFailure.unavailable }
        frames += 1
        return ObservationFrame(image: patternedImage(),capturedAt: Date(),diagnostic: nil)
    }
}
private actor ObservationTestTransport: ObservationTransport {
    let session = "44e91877-fc56-4aaf-a8bc-a2d7b75d579f"
    var observations: [JSONValue] = []
    var operations: [String: JSONValue] = [:]
    var requests: [String: JSONValue] = [:]
    var mediaIDs: [String] = []
    var batchIDs: [String] = []
    var loseBatchReply = false
    var hardFailure = false
    var duplicateReceipts = false
    var corruptInventory = false
    var finalState = "OPEN"
    func configure(lose: Bool = false,hard: Bool = false,duplicate: Bool = false,corrupt: Bool = false) { loseBatchReply = lose; hardFailure = hard; duplicateReceipts = duplicate; corruptInventory = corrupt }
    func snapshot() -> ([String],[String],Int,String) { (mediaIDs,batchIDs,observations.count,finalState) }
    func send(path: String,method: String,payload: JSONValue?,crop: Data?) async throws -> JSONValue {
        if method == "GET" {
            return .object(["session_id": .string(session),"entries": .array(observations.map { observation in
                var result = observation
                if corruptInventory,case .object(var fields) = result { fields["track_id"] = .string("wrong"); result = .object(fields) }
                return .object(["observation": result,"crop_status": .string("available")])
            }),"tracks": .array([]),"next_cursor": .null])
        }
        guard case .object(let p) = payload,case .string(let operation) = p["operation_id"] else { throw ObservationFailure.invalidResponse }
        if path.hasSuffix("/media") { mediaIDs.append(operation) }
        if path.hasSuffix("/batches") { batchIDs.append(operation) }
        if let original = requests[operation],original != payload { throw ObservationFailure.invalidResponse }
        requests[operation] = payload
        if let previous = operations[operation] { return previous }
        let result: JSONValue
        if path == "/sessions" {
            result = .object(["operation_id": .string(operation),"session": .object(["session_id": .string(session),"state": .string("OPEN"),"embodiment_id": .string("embodiment:test"),"expires_at": .string(V1Time.format(Date().addingTimeInterval(900)))])])
        } else if path.hasSuffix("/media") {
            guard crop != nil else { throw ObservationFailure.invalidResponse }
            result = .object(["operation_id": .string(operation),"crop": p["crop"]!,"disposition": .string("accepted")])
        } else if path.hasSuffix("/batches") {
            if hardFailure { throw ObservationFailure.server(403,"denied",false,0) }
            guard case .array(let values) = p["observations"],case .object(let observation) = values.first else { throw ObservationFailure.invalidResponse }
            if !observations.contains(values[0]) { observations.append(values[0]) }
            result = .object(["operation_id": .string(operation),"receipts": .array([.object(["observation_id": observation["observation_id"]!,"disposition": .string(duplicateReceipts ? "duplicate" : "accepted"),"error": .null])])])
        } else if path.hasSuffix("/end") {
            finalState = try p.field("state").string()
            result = .object(["operation_id": .string(operation),"session": .object(["session_id": .string(session),"state": .string(finalState)])])
        } else { throw ObservationFailure.invalidResponse }
        operations[operation] = result
        if loseBatchReply,path.hasSuffix("/batches") { loseBatchReply = false; throw URLError(.networkConnectionLost) }
        return result
    }
}
final class ObjectObservationTests: XCTestCase {
    private let box = ObservationBox(x: 0.1,y: 0.1,width: 0.25,height: 0.3)
    private func proposal(_ box: ObservationBox) -> ObservationProposal { ObservationProposal(box: box,objectness: nil,visibility: 1) }
    private func crop(id: String = observationID(),track: String = "track:test",hash: UInt64 = 0,quality: Double = 0.5,bytes: Int = 10) -> ObservationCrop {
        ObservationCrop(id: id,trackID: track,jpeg: Data(repeating: 1,count: bytes),width: 50,height: 90,sourceWidth: 200,sourceHeight: 300,box: box,capturedAt: Date(),sequence: 1,quality: quality,fingerprint: hash,diagnostic: nil,objectness: nil)
    }
    func testStableTrackIDsAndContinuity() {
        var tracker = ObservationTracker(); let t = Date()
        let first = tracker.update([proposal(box)],at: t,world: nil)
        let moved = ObservationBox(x: 0.12,y: 0.11,width: 0.25,height: 0.3)
        let second = tracker.update([proposal(moved)],at: t.addingTimeInterval(1),world: nil)
        XCTAssertEqual(first[0].0.id,second[0].0.id); XCTAssertEqual(second[0].0.sightings,2)
    }
    func testDuplicateDetectionsAndSimilarSimultaneousObjects() {
        var tracker = ObservationTracker(); let t = Date()
        let other = ObservationBox(x: 0.6,y: 0.1,width: 0.25,height: 0.3)
        let results = tracker.update([proposal(box),proposal(box),proposal(other)],at: t,world: nil)
        XCTAssertEqual(results.count,2); XCTAssertNotEqual(results[0].0.id,results[1].0.id)
        let next = tracker.update([proposal(other),proposal(box)],at: t.addingTimeInterval(1),world: nil)
        XCTAssertEqual(Set(results.map { $0.0.id }),Set(next.map { $0.0.id }))
    }
    func testOcclusionAndExpiry() {
        var tracker = ObservationTracker(); let t = Date()
        let id = tracker.update([proposal(box)],at: t,world: nil)[0].0.id
        XCTAssertTrue(tracker.update([],at: t.addingTimeInterval(1),world: nil).isEmpty)
        XCTAssertEqual(tracker.update([proposal(box)],at: t.addingTimeInterval(3),world: nil)[0].0.id,id)
        XCTAssertNotEqual(tracker.update([proposal(box)],at: t.addingTimeInterval(8),world: nil)[0].0.id,id)
    }
    func testAmbiguousAssociationsStaySeparateAndBounded() {
        var tracker = ObservationTracker(); tracker.maxTracks = 3; let t = Date()
        let a = ObservationBox(x: 0.1,y: 0.1,width: 0.3,height: 0.3), b = ObservationBox(x: 0.2,y: 0.1,width: 0.3,height: 0.3)
        let first = tracker.update([proposal(a),proposal(b)],at: t,world: nil)
        let ambiguous = ObservationBox(x: 0.15,y: 0.1,width: 0.3,height: 0.3)
        let next = tracker.update([proposal(ambiguous)],at: t.addingTimeInterval(1),world: nil)
        XCTAssertFalse(first.map { $0.0.id }.contains(next[0].0.id))
        XCTAssertLessThanOrEqual(tracker.tracks.count,3)
    }
    func testAppearanceRejectsSwitchButDoesNotMergeSimilarObjects() throws {
        let image = patternedImage()
        let redImage = try XCTUnwrap(image.cropping(to: CGRect(x: 0,y: 0,width: 200,height: 140)))
        let red = try XCTUnwrap(ObservationAppearance(image: redImage))
        let blueImage = try XCTUnwrap(image.cropping(to: CGRect(x: 0,y: 160,width: 200,height: 140)))
        let blue = try XCTUnwrap(ObservationAppearance(image: blueImage))
        XCTAssertEqual(red.distance(to: red),0)
        XCTAssertTrue(red.compatible(with: red)); XCTAssertFalse(red.compatible(with: blue))
        var tracker = ObservationTracker(); let time = Date()
        var seed = proposal(box); seed.appearance = red
        let first = tracker.update([seed],at: time,world: nil)[0].0.id
        var changed = seed; changed.appearance = blue
        XCTAssertNotEqual(tracker.update([changed],at: time.addingTimeInterval(1),world: nil)[0].0.id,first)
        tracker.reset()
        let other = ObservationProposal(box: ObservationBox(x: 0.6,y: 0.1,width: 0.25,height: 0.3),objectness: nil,visibility: 1,appearance: red)
        let simultaneous = tracker.update([seed,other],at: time,world: nil)
        XCTAssertEqual(simultaneous.count,2); XCTAssertNotEqual(simultaneous[0].0.id,simultaneous[1].0.id)
        seed.manualSeed = true
        XCTAssertFalse(simultaneous.map { $0.0.id }.contains(tracker.update([seed],at: time.addingTimeInterval(1),world: nil)[0].0.id))
    }
    func testThermalBudgetBacksOffAndStops() {
        XCTAssertEqual(ObservationThermalPolicy.interval(1.5,rawState: 0),1.5)
        XCTAssertEqual(ObservationThermalPolicy.interval(1.5,rawState: 1),3)
        XCTAssertFalse(ObservationThermalPolicy.stop(1)); XCTAssertTrue(ObservationThermalPolicy.stop(2)); XCTAssertTrue(ObservationThermalPolicy.stop(3))
    }
    func testNoDetectionsWorldResetAndSessionReset() {
        var tracker = ObservationTracker(); let t = Date()
        XCTAssertTrue(tracker.update([],at: t,world: nil).isEmpty)
        let id = tracker.update([proposal(box)],at: t,world: "tracking:a")[0].0.id
        XCTAssertNotEqual(tracker.update([proposal(box)],at: t,world: "tracking:b")[0].0.id,id)
        tracker.reset(); XCTAssertEqual(tracker.totalCreated,0); XCTAssertTrue(tracker.tracks.isEmpty)
    }
    func testCropSelectionDeduplicatesRanksAndBoundsBytes() {
        var selector = ObservationSelector(perTrack: 3,maxBytes: 30)
        selector.offer(crop()); selector.offer(crop(quality: 0.9))
        XCTAssertEqual(selector.crops.count,1); XCTAssertEqual(selector.crops[0].quality,0.9)
        selector.offer(crop(hash: .max)); selector.offer(crop(hash: 0xAAAAAAAAAAAAAAAA)); selector.offer(crop(hash: 0x5555555555555555,quality: 1))
        XCTAssertEqual(selector.crops.count,3); XCTAssertLessThanOrEqual(selector.bytes,30)
        selector.offer(crop(track: "track:second",hash: 20,bytes: 50)); XCTAssertEqual(selector.crops.count,3)
    }
    func testUnknownCategoryMissingPoseAndManualProvenance() throws {
        let wire = try crop().wire(session: observationID(),mode: .manual).object(required: ["observation_id","session_id","track_id","captured_at","crop","region","coordinate_frame","provenance"])
        XCTAssertNil(wire["category_hint"]); XCTAssertNil(wire["detection_score"]); XCTAssertNil(wire["camera_pose"]); XCTAssertNil(wire["camera_measurements"])
        XCTAssertEqual(try wire.field("provenance").object(required: ["camera_id","producer_profile_id","capture_sequence"])["producer_profile_id"],.string(ObservationMode.manual.profile))
        XCTAssertNotEqual(ObservationMode.manual.profile,ObservationMode.automatic.profile)
    }
    func testCapturePoseUsesExistingOpticalAxesWithoutChangingARGeometry() throws {
        let ar = try RigidTransform(rotation: simd_quatd(angle: 0,axis: SIMD3(0,1,0)),translation: SIMD3(1,2,3))
        let optical = try ARLocalTracking.opticalPose(ar)
        XCTAssertEqual(optical.translation,ar.translation)
        XCTAssertLessThan(simd_distance(optical.rotation.act(SIMD3(0,0,1)),SIMD3(0,0,-1)),1e-8)
        XCTAssertLessThan(simd_distance(optical.rotation.act(SIMD3(0,1,0)),SIMD3(0,-1,0)),1e-8)
        XCTAssertLessThan(simd_distance(ar.rotation.act(SIMD3(0,0,1)),SIMD3(0,0,1)),1e-8)
    }
    func testUnalignedLocalPoseRetainsExactCaptureReference() throws {
        var value = crop()
        let pose = JSONValue.object(["pose_id": .string("pose:example"),"frame": .object(["frame_id": .string("tracking:example"),"kind": .string("device_local")]),"measured_at": .string(V1Time.format(value.capturedAt)),"pose_frame": .string("camera_optical")])
        value.pose = pose
        let wire = try value.wire(session: observationID(),mode: .manual).object(required: ["observation_id","session_id","track_id","captured_at","crop","region","coordinate_frame","provenance","camera_pose"])
        XCTAssertEqual(wire["camera_pose"],pose); XCTAssertNil(wire["household_id"])
    }
    func testCropPixelsMetadataOrientationAndFullFrameGuard() async throws {
        let processor = ObservationProcessor(); await processor.reset(settings: ObservationSettings())
        let frame = ObservationFrame(image: patternedImage(),capturedAt: Date(),diagnostic: nil)
        let result = try await processor.process(frame,mode: .manual,manual: [box])
        let value = try XCTUnwrap(result.crops.first)
        XCTAssertEqual(value.sourceWidth,200); XCTAssertEqual(value.sourceHeight,300)
        XCTAssertEqual(value.capturedAt,frame.capturedAt)
        XCTAssertEqual(value.width,Int(value.box.width*200)); XCTAssertEqual(value.height,Int(value.box.height*300))
        let image = try XCTUnwrap(CGImageSourceCreateWithData(value.jpeg as CFData,nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image,0,nil))
        XCTAssertEqual(decoded.width,value.width); XCTAssertEqual(decoded.height,value.height)
        XCTAssertLessThan(decoded.width*decoded.height,200*300)
        let rejected = try await processor.process(frame,mode: .manual,manual: [ObservationBox(x: 0,y: 0,width: 1,height: 1)])
        XCTAssertLessThanOrEqual(rejected.crops.count,3)
        // Actual top-half red pixels survive upright top-left cropping.
        var pixel = [UInt8](repeating: 0,count: 4)
        let ctx = CGContext(data: &pixel,width: 1,height: 1,bitsPerComponent: 8,bytesPerRow: 4,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(decoded,in: CGRect(x: 0,y: 0,width: 1,height: 1)); XCTAssertGreaterThan(pixel[0],pixel[2])
    }
    func testExportSyntheticWireFixtureForServerIntegration() async throws {
        let processor = ObservationProcessor(); await processor.reset(settings: ObservationSettings())
        let frame = ObservationFrame(image: patternedImage(),capturedAt: Date(),diagnostic: nil)
        let result = try await processor.process(frame,mode: .manual,manual: [box])
        let value = try XCTUnwrap(result.crops.first)
        let fixture = JSONValue.object(["observation": value.wire(session: observationID(),mode: .manual),"jpeg": .string(value.jpeg.base64EncodedString())])
        let directory = FileManager.default.urls(for: .documentDirectory,in: .userDomainMask)[0]
        try JSONEncoder().encode(fixture).write(to: directory.appendingPathComponent("observation-wire-fixture.json"),options: .atomic)
    }
    func testQueuePersistsIDsProtectsBoundsAndExpires() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(observationID())
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ObservationQueueStore(directory: root)
        var queue = ObservationQueue(body: "embodiment:test",client: "client:test",origin: "https://example.test",mode: .manual,startOperation: observationID(),expiresAt: Date().addingTimeInterval(60))
        queue.uploads = [ObservationUpload(crop: crop())]; try store.save(queue)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.startOperation,queue.startOperation); XCTAssertEqual(loaded.uploads[0].batchOperation,queue.uploads[0].batchOperation)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.file)) as? [String:Any])
        var metrics = try XCTUnwrap(old["metrics"] as? [String:Any]); metrics.removeValue(forKey: "captureFailures"); old["metrics"] = metrics
        try JSONSerialization.data(withJSONObject: old).write(to: store.file,options: .atomic)
        XCTAssertEqual(try store.load()?.startOperation,queue.startOperation)
        XCTAssertFalse(loaded.bound(to: ObservationAccess(body: "embodiment:other",client: queue.client,origin: queue.origin,transport: ObservationTestTransport())))
        XCTAssertNil(try store.load(now: Date().addingTimeInterval(61))); XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
    }
    @MainActor private func setup() throws -> (ObservationSessionManager,ObservationTestCamera,ObservationTestTransport,ObservationQueueStore,ObservationAccess) {
        let store = try ObservationQueueStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(observationID()))
        let camera = ObservationTestCamera(), transport = ObservationTestTransport()
        let access = ObservationAccess(body: "embodiment:test",client: "client:test",origin: "https://example.test",transport: transport)
        let manager = ObservationSessionManager(camera: camera,store: store,thermalState: { 0 }); manager.localOnly = false
        return (manager,camera,transport,store,access)
    }
    @MainActor private func wait(_ condition: @MainActor () -> Bool,seconds: Double = 5) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(),Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
    @MainActor private func captured(_ manager: ObservationSessionManager,_ access: ObservationAccess) async throws {
        manager.begin(access: { access }); try await wait { manager.frame != nil }
        manager.holdManualFrame(); manager.select(box)
        try await wait { !manager.crops.isEmpty }
    }
    @MainActor func testSessionLifecycleWithoutDetections() async throws {
        let (manager,_,_,store,access) = try setup(); defer { try? FileManager.default.removeItem(at: store.directory) }
        XCTAssertEqual(manager.phase,.idle); manager.begin(access: { access })
        try await wait { manager.phase == .capturing }; manager.finish()
        try await wait { manager.phase == .completed }; XCTAssertEqual(manager.inventory.count,0); XCTAssertFalse(manager.hasQueue)
    }
    @MainActor func testInterruptedCaptureDoesNotRestartAndKeepsQueue() async throws {
        let (manager,camera,_,store,access) = try setup(); defer { try? FileManager.default.removeItem(at: store.directory) }
        manager.begin(access: { access }); try await wait { manager.frame != nil }; manager.interrupt()
        let count = camera.frames; try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager.phase,.failed); XCTAssertEqual(camera.frames,count)
        let recovered = ObservationSessionManager(camera: camera,store: store,thermalState: { 0 })
        XCTAssertTrue(recovered.hasQueue); XCTAssertEqual(recovered.phase,.failed)
        recovered.cancel(); recovered.retry(access: { access })
        try await wait { recovered.phase == .cancelled }; XCTAssertNil(try store.load())
    }
    @MainActor func testLostReplyRetriesSameOperationWithoutDuplicateObservation() async throws {
        let (manager,_,transport,store,access) = try setup(); defer { try? FileManager.default.removeItem(at: store.directory) }
        await transport.configure(lose: true)
        try await captured(manager,access); let ids = manager.crops.map(\.id)
        manager.finish(); try await wait({ manager.phase == .completed },seconds: 10)
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.2,ids.count); XCTAssertEqual(Set(snapshot.1).count,ids.count); XCTAssertGreaterThan(snapshot.1.count,ids.count)
        XCTAssertEqual(manager.inventory.count,ids.count); XCTAssertNil(try store.load())
    }
    @MainActor func testFailedUploadSurvivesRelaunchAndDuplicateAcknowledgement() async throws {
        let (manager,camera,transport,store,access) = try setup(); defer { try? FileManager.default.removeItem(at: store.directory) }
        await transport.configure(hard: true)
        try await captured(manager,access); manager.finish(); try await wait { manager.phase == .failed }
        let saved = try XCTUnwrap(store.load())
        let recovered = ObservationSessionManager(camera: camera,store: store,thermalState: { 0 })
        await transport.configure(duplicate: true)
        recovered.retry(access: { access }); try await wait { recovered.phase == .completed }
        let snapshot = await transport.snapshot()
        XCTAssertEqual(Set(snapshot.1),Set(saved.uploads.map(\.batchOperation))); XCTAssertEqual(snapshot.2,saved.uploads.count)
        XCTAssertEqual(recovered.acknowledged,saved.uploads.count)
    }
    @MainActor func testSeriousThermalStateKeepsQueueWithoutOpeningCamera() async throws {
        let (_,camera,_,store,access) = try setup(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let manager = ObservationSessionManager(camera: camera,store: store,thermalState: { 2 })
        manager.thermalGuardEnabled = true
        manager.localOnly = true; manager.begin(access: { access })
        try await wait { manager.phase == .failed }
        XCTAssertEqual(camera.frames,0); XCTAssertTrue(manager.hasQueue)
        XCTAssertEqual(manager.metrics.captureFailures,1); XCTAssertEqual(manager.metrics.uploadFailures,0)
        XCTAssertTrue(manager.message?.contains("thermal") == true)
        let recovered = ObservationSessionManager(camera: camera,store: store,thermalState: { 0 })
        XCTAssertTrue(recovered.canBegin); XCTAssertTrue(recovered.localOnly); XCTAssertFalse(recovered.hasQueue)
        manager.cancel(); XCTAssertEqual(manager.phase,.cancelled); XCTAssertFalse(manager.hasQueue)
    }
    @MainActor func testUserCanDisableAppThermalBudgetForDiagnostics() async throws {
        let (_,camera,_,store,access) = try setup(); defer { try? FileManager.default.removeItem(at: store.directory) }
        let manager = ObservationSessionManager(camera: camera,store: store,thermalState: { 2 })
        manager.localOnly = true; manager.thermalGuardEnabled = false; manager.begin(access: { access })
        try await wait { manager.frame != nil }
        XCTAssertEqual(manager.phase,.capturing); XCTAssertGreaterThan(camera.frames,0)
        manager.finish(); XCTAssertEqual(manager.phase,.completed)
    }
    @MainActor func testLocalDiagnosticNeverCallsServerAndCanCancelOrComplete() async throws {
        let (manager,_,transport,store,access) = try setup(); defer { try? FileManager.default.removeItem(at: store.directory) }
        manager.localOnly = true
        try await captured(manager,access); manager.finish()
        XCTAssertEqual(manager.phase,.completed); XCTAssertTrue(manager.inventory.isEmpty)
        let first = await transport.snapshot(); XCTAssertEqual(first.2,0); XCTAssertTrue(first.0.isEmpty)
        manager.begin(access: { access }); try await wait { manager.phase == .capturing }; manager.cancel()
        XCTAssertEqual(manager.phase,.cancelled); XCTAssertFalse(manager.hasQueue)
    }
    @MainActor func testRejectedManualBoxReleasesHeldFrameAndAllowsAnotherSelection() async throws {
        let (manager,camera,_,store,access) = try setup(); defer { try? FileManager.default.removeItem(at: store.directory) }
        manager.localOnly = true; manager.begin(access: { access }); try await wait { manager.frame != nil }
        let before = camera.frames
        manager.holdManualFrame(); manager.select(ObservationBox(x: 0,y: 0,width: 1,height: 1))
        XCTAssertTrue(manager.message?.contains("not accepted") == true)
        try await wait { camera.frames > before }
        manager.holdManualFrame(); manager.select(box); try await wait { !manager.crops.isEmpty }
        manager.finish(); XCTAssertEqual(manager.phase,.completed)
    }
    @MainActor func testCancellationConfirmsRemoteStateAndCleansQueue() async throws {
        let (manager,_,transport,store,access) = try setup(); defer { try? FileManager.default.removeItem(at: store.directory) }
        manager.begin(access: { access }); try await wait { manager.phase == .capturing }; manager.cancel()
        try await wait { manager.phase == .cancelled }
        let snapshot = await transport.snapshot(); XCTAssertEqual(snapshot.3,"CANCELLED"); XCTAssertEqual(snapshot.2,0); XCTAssertFalse(manager.hasQueue)
    }
    @MainActor func testCorruptInventoryCannotClaimCompletion() async throws {
        let (manager,_,transport,store,access) = try setup(); defer { try? FileManager.default.removeItem(at: store.directory) }
        await transport.configure(corrupt: true)
        try await captured(manager,access); manager.finish(); try await wait { manager.phase == .failed }
        XCTAssertTrue(manager.hasQueue); XCTAssertFalse(manager.canCancel)
        await transport.configure(); manager.retry(access: { access }); try await wait { manager.phase == .completed }
    }
}

/// Opt-in hardware experiment. A simulator cannot establish any of these measurements.
final class PhysicalObjectObservationTests: XCTestCase {
    @MainActor func testAutomaticForeground60SecondBaseline() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPhone and explicit observation-evaluation.json required.")
        #else
        let documents = FileManager.default.urls(for: .documentDirectory,in: .userDomainMask)[0]
        let marker = documents.appendingPathComponent("observation-evaluation.json")
        guard let data = try? Data(contentsOf: marker),data.count <= 4096,
              case .object(let config) = try JSONValue.decode(data),config["baseline"] == .bool(true) else {
            throw XCTSkip("Create the explicit hardware evaluation marker after arranging the controlled room.")
        }
        let phone = AppRuntime.embodiment
        guard phone.isEnabled,phone.cameraSelected,phone.vision.camera.availability == nil else { throw XCTSkip("Existing DEVICE camera permission and identity required.") }
        phone.setForeground(true); phone.enableRuntime()
        let deadline = Date().addingTimeInterval(30)
        while !phone.isOnline,Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(phone.isOnline)
        let body = try XCTUnwrap(phone.embodimentID)
        try await phone.localization.camera.beginObservationAcquisition()
        defer { phone.localization.camera.endObservationAcquisition() }
        let trackingStart = phone.localization.camera.tracking.sequence
        let processor = ObservationProcessor(); await processor.reset(settings: ObservationSettings())
        var rawBoxes: [[ObservationBox]] = []
        var acquisitionMS: [Double] = [],trackingStates: [String:Int] = [:]
        var snapshotMS: Double?
        var proposalsMS: [Double] = [],trackingMS: [Double] = []
        var latencies: [Double] = [],times: [Date] = [],thermal: [Int] = [],sightings: [String:Int] = [:],crops: [ObservationCrop] = []
        var created = 0,peak: UInt64 = 0,failures = 0
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryStart = UIDevice.current.batteryLevel
        let start = ContinuousClock.now
        print("HC_E2_03_PHYSICAL_CAPTURE_STARTED — 60 seconds")
        while start.duration(to: .now) < .seconds(60) {
            let next = ContinuousClock.now.advanced(by: .milliseconds(1500))
            do {
                let acquired = ContinuousClock.now
                let frame = try await phone.localization.camera.observationFrame(body: body)
                let acquiredDuration = acquired.duration(to: .now)
                acquisitionMS.append(Double(acquiredDuration.components.seconds)*1000+Double(acquiredDuration.components.attoseconds)/1e15)
                if case .object(let diagnostic) = frame.diagnostic,case .string(let state) = diagnostic["tracking_state"] { trackingStates[state,default: 0] += 1 }
                let result = try await processor.process(frame,mode: .automatic,manual: [])
                rawBoxes.append(result.rawProposalBoxes); times.append(frame.capturedAt); proposalsMS.append(result.proposalLatencyMS); trackingMS.append(result.trackingLatencyMS); latencies.append(result.latencyMS); crops = result.crops; created = result.totalTracks
                for track in result.tracks { sightings[track.id] = track.sightings }
                var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<integer_t>.size)
                let status = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self,capacity: Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) } }
                if status == KERN_SUCCESS { peak = max(peak,info.phys_footprint) }
                thermal.append(ProcessInfo.processInfo.thermalState.rawValue)
            } catch { failures += 1; print("HC_E2_03_SAMPLE_ERROR \(error.localizedDescription)") }
            if config["snapshot_probe"] == .bool(true),snapshotMS == nil,start.duration(to: .now) > .seconds(30) {
                let snapshotStart = ContinuousClock.now
                do {
                    _ = try await phone.vision.camera.captureFreshImage(deadline: Date().addingTimeInterval(8))
                    let dt = snapshotStart.duration(to: .now)
                    snapshotMS = Double(dt.components.seconds)*1000+Double(dt.components.attoseconds)/1e15
                } catch { snapshotMS = -1; failures += 1 }
            }
            if next > .now { try await Task.sleep(until: next,clock: .continuous) }
        }
        let folder = documents.appendingPathComponent("ObservationHardware",isDirectory: true)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        for crop in crops { try crop.jpeg.write(to: folder.appendingPathComponent(crop.id+".jpg"),options: .atomic) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        let report = JSONValue.object(["mode": .string("automatic foreground, hardware baseline; no server upload"),"device": .string(UIDevice.current.model),"os": .string(UIDevice.current.systemVersion),
            "samples": .integer(Int64(times.count)),"timestamps": .array(times.map { .string(V1Time.format($0)) }),"processing_ms": .array(latencies.map { .number($0) }),
            "acquisition_ms": .array(acquisitionMS.map { .number($0) }),"local_tracking_sequence_delta": .integer(phone.localization.camera.tracking.sequence-trackingStart),"local_tracking_states": .object(trackingStates.mapValues { .integer(Int64($0)) }),"snapshot_ms": snapshotMS.map { .number($0) } ?? .null,
            "raw_proposal_boxes": .array(rawBoxes.map { .array($0.map(\.wire)) }),
            "proposal_ms": .array(proposalsMS.map { .number($0) }),"tracking_ms": .array(trackingMS.map { .number($0) }),
            "tracks_created": .integer(Int64(created)),"track_sightings": .object(sightings.mapValues { .integer(Int64($0)) }),"selected_crops": .integer(Int64(crops.count)),"crop_bytes": .integer(Int64(crops.reduce(0) { $0+$1.jpeg.count })),
            "peak_sampled_phys_footprint_bytes": .integer(Int64(peak)),"battery_start": .number(Double(batteryStart)),"battery_end": .number(Double(UIDevice.current.batteryLevel)),"thermal_states": .array(thermal.map { .integer(Int64($0)) }),"sample_errors": .integer(Int64(failures)),
            "crop_metadata": .array(crops.map { $0.wire(session: "00000000-0000-4000-8000-000000000000",mode: .automatic) })])
        try encoder.encode(report).write(to: folder.appendingPathComponent("baseline.json"),options: .atomic)
        XCTAssertFalse(times.isEmpty,"No real camera samples were processed")
        print("HC_E2_03_PHYSICAL_CAPTURE_FINISHED samples=\(times.count) tracks=\(created) crops=\(crops.count) errors=\(failures)")
        #endif
    }
}
