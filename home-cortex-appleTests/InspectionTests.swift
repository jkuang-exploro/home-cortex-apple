import XCTest
import UIKit
@testable import HomeCortex

@MainActor private final class PreviewCamera: InspectionCamera {
    var starts = 0
    var stops = 0
    var sink: (@Sendable (InspectionImage) -> Void)?
    func startPreview(fps: Int, deliver: @escaping @Sendable (InspectionImage) -> Void) async throws { starts += 1; sink = deliver }
    func stopPreview() { stops += 1; sink = nil }
}
private actor PreviewTransport: InspectionTransport {
    var viewing = false
    var frames: [JSONValue] = []
    var expiry = Date().addingTimeInterval(12)
    func enable(expiry: Date? = nil) { viewing = true; if let expiry { self.expiry = expiry } }
    func send(bodyID: String, sessionID: String, frame: JSONValue?) async throws -> JSONValue {
        if let frame { frames.append(frame); return .null }
        return .object(["active": .bool(viewing), "fps": .integer(viewing ? 3 : 0), "expires_at": viewing ? .string(V1Time.format(expiry)) : .null])
    }
    func count() -> Int { frames.count }
}
final class InspectionTests: XCTestCase {
    private func image(_ sequence: Int = 0) -> InspectionImage {
        InspectionImage(jpeg: Data([0xff,0xd8,0xff,0xd9]), capturedAt: Date(), width: 360, height: 640)
    }
    @MainActor func testClosedFrameContractIsSeparateFromEvidenceAndMailboxIsLatestOnly() throws {
        let value = try InspectionPublisher.frame(image(), body: "embodiment:phone", sequence: 4)
        let fields = try value.object(required: ["embodiment_id", "camera_id", "sequence", "captured_at", "width", "height", "mime_type", "media"])
        XCTAssertEqual(fields["camera_id"], .string("rear.main")); XCTAssertNil(fields["evidence_id"])
        let mailbox = InspectionMailbox()
        var newest: InspectionImage?
        for _ in 0..<10000 { let next = image(); newest = next; mailbox.put(next) }
        XCTAssertEqual(mailbox.take()?.capturedAt, newest?.capturedAt)
        XCTAssertNil(mailbox.take())
        mailbox.put(image()); mailbox.clear(); XCTAssertNil(mailbox.take())
    }
    @MainActor func testIdleDoesNotOpenCameraAndPublishingStopsWithForeground() async throws {
        let camera = PreviewCamera(); let transport = PreviewTransport(); let publisher = InspectionPublisher(camera: camera)
        publisher.start(access: { ("embodiment:phone", "session:one", transport) }, active: { true })
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(camera.starts, 0); let idleCount = await transport.count(); XCTAssertEqual(idleCount, 0)
        XCTAssertFalse(publisher.isPublishing)
        publisher.stop()
        await transport.enable()
        publisher.start(access: { ("embodiment:phone", "session:one", transport) }, active: { true })
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertGreaterThan(camera.starts, 0)
        XCTAssertTrue(publisher.isPublishing)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        camera.sink?(image())
        try await Task.sleep(for: .milliseconds(160))
        let count = await transport.count(); XCTAssertEqual(count, 1)
        publisher.stop()
        let old = camera.starts
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(camera.starts, old); XCTAssertNil(camera.sink)
        XCTAssertFalse(publisher.isPublishing)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }
    @MainActor func testLeaseExpiresEvenWhileNextNetworkPollHasNotRun() async throws {
        let camera = PreviewCamera(); let transport = PreviewTransport(); let publisher = InspectionPublisher(camera: camera)
        await transport.enable(expiry: Date().addingTimeInterval(0.25))
        publisher.start(access: { ("embodiment:phone", "session:one", transport) }, active: { true })
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(camera.starts, 1)
        XCTAssertTrue(publisher.isPublishing)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(camera.sink)
        XCTAssertEqual(publisher.status, "Idle — viewer lease expired")
        XCTAssertFalse(publisher.isPublishing)
        publisher.stop()
    }
    @MainActor func testLocalPauseAndInactiveDeviceCannotPublish() async throws {
        let camera = PreviewCamera(); let transport = PreviewTransport(); let publisher = InspectionPublisher(camera: camera)
        await transport.enable()
        publisher.paused = true
        publisher.start(access: { ("embodiment:phone", "session:one", transport) }, active: { true })
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(camera.starts, 0)
        publisher.stop(); publisher.paused = false
        publisher.start(access: { ("embodiment:phone", "session:one", transport) }, active: { false })
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(camera.starts, 0); let count = await transport.count(); XCTAssertEqual(count, 0)
        publisher.stop()
    }
}
