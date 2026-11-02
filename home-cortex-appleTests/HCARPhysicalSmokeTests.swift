import XCTest
import AVFoundation
@testable import HomeCortex

final class HCARPhysicalSmokeTests: XCTestCase {
    @MainActor func testExistingCameraSnapshotsAndRestartDuringLocalScan() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical iPhone with existing camera permission.")
        #else
        let phone = AppRuntime.embodiment
        phone.setForeground(false)
        defer { phone.setForeground(true) }
        let camera = phone.localization.camera
        guard camera.availability == nil, camera.tracking.supported else { throw XCTSkip("Physical rear camera permission / ARKit unavailable.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(observationID())
        let store = try ObservationQueueStore(directory: root)
        let manager = ObservationSessionManager(camera: camera,store: store,thermalState: { 0 })
        manager.localOnly = true; manager.settings.sampleInterval = 1
        let access = ObservationAccess(body: "embodiment:local-smoke",client: "client:local-smoke",origin: "https://example.invalid",transport: NoUpload())
        await camera.useTracking(true)
        defer { manager.interrupt(); camera.stopTracking(); try? FileManager.default.removeItem(at: root) }
        manager.begin(access: { access })
        try await wait { manager.frame != nil }
        let world = try XCTUnwrap(camera.tracking.worldID)
        for _ in 0..<2 {
            let requested = Date()
            let image = try await camera.captureFreshImage(deadline: requested.addingTimeInterval(5))
            XCTAssertGreaterThanOrEqual(image.capturedAt,requested)
            XCTAssertEqual(camera.tracking.worldID,world)
            XCTAssertEqual(manager.phase,.capturing)
            XCTAssertLessThanOrEqual(image.jpeg.count,VisualEvidence.maxMediaBytes)
        }
        manager.holdManualFrame(); manager.select(ObservationBox(x: 0.2,y: 0.2,width: 0.3,height: 0.3))
        try await wait { !manager.crops.isEmpty }
        let ids = manager.crops.map(\.id)
        XCTAssertEqual(try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,true)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.file.path)[.protectionKey] as? FileProtectionType,.complete)
        camera.tracking.start(resetReason: "HC-AR-01 local smoke reset")
        let resetWorld = try XCTUnwrap(camera.tracking.worldID)
        XCTAssertNotEqual(resetWorld,world)
        try await wait { manager.frame?.world == resetWorld }
        XCTAssertEqual(manager.phase,.capturing)
        XCTAssertTrue(Set(ids).isSubset(of: Set(manager.crops.map(\.id))))
        manager.finish(); try await wait { manager.phase == .completed && !manager.busy }
        XCTAssertFalse(manager.hasQueue)
        // Exercise the same AVFoundation output with AR ownership released.
        await camera.useTracking(false)
        try await camera.beginObservationAcquisition()
        defer { camera.endObservationAcquisition() }
        let sample = try await camera.observationFrame(body: access.body)
        let requested = Date(), image = try await camera.captureFreshImage(deadline: Date().addingTimeInterval(5))
        XCTAssertGreaterThanOrEqual(image.capturedAt,requested)
        XCTAssertGreaterThan(image.capturedAt,sample.capturedAt)
        print("HC_AR_PHYSICAL_SMOKE passed: two fresh AR snapshots, crop IDs across AR reset, AVFoundation sample + fresh snapshot; no server upload")
        #endif
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }
}
private struct NoUpload: ObservationTransport {
    func send(path: String,method: String,payload: JSONValue?,crop: Data?) async throws -> JSONValue { throw ObservationFailure.invalidResponse }
}
