import XCTest
import AVFoundation
@testable import HomeCortex

@MainActor private final class FakeStillCamera: StillImageCapture {
    var availability: VisionFailure?
    var permissionLabel = "Allowed"
    var calls = 0
    var failure: VisionFailure?
    var stale = false
    var delay = false
    func requestPermission() async { }
    func cancel() { }
    func captureFreshImage(deadline: Date) async throws -> CapturedImage {
        calls += 1
        if delay { try await Task.sleep(for: .milliseconds(100)) }
        if let failure { throw failure }
        return CapturedImage(jpeg: Data([0xff,0xd8,UInt8(calls),0xff,0xd9]), capturedAt: stale ? .distantPast : Date(), cameraID: "camera:rear-primary", width: 1, height: 1, captureDuration: 0.01, encodingDuration: 0.001)
    }
}
final class VisionTests: XCTestCase {
    @MainActor private func fixture(_ name: String) throws -> JSONValue {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONValue.decode(Data(contentsOf: url))
    }
    @MainActor private func request(now: Date = Date(), expired: Bool = false) -> JSONValue {
        let id = UUID().uuidString.lowercased()
        return .object(["protocol_version": .string("1.0"), "schema_name": .string("hc.request"), "schema_version": .integer(1),
            "message_id": .string(id), "request_id": .string(id), "sent_at": .string(V1Time.format(expired ? now.addingTimeInterval(-20) : now.addingTimeInterval(-1))),
            "deadline_at": .string(V1Time.format(expired ? now.addingTimeInterval(-1) : now.addingTimeInterval(10))),
            "target": .object(["embodiment_id": .string("embodiment:phone"), "session_id": .string("runtime-session:one")]),
            "operation": .string("vision.observe"), "arguments": .object([:])])
    }
    @MainActor func testSharedPythonGoldenVectorsAndEscaping() throws {
        for name in ["visual-evidence", "visual-evidence-unicode"] {
            guard case .object(let vector) = try fixture(name) else { return XCTFail() }
            var fields = try (vector["manifest"] ?? vector["manifest_without_evidence_id"]!).object(required: ["embodiment_id","camera_id","media_type","captured_start","captured_end","duration_ms","sequence_start","sequence_end","width","height","content_type","sha256","reason"], optional: ["evidence_id"])
            let expected = fields.removeValue(forKey: "evidence_id") ?? vector["evidence_id"]!
            XCTAssertEqual(try V1Canonical.text(.object(fields)), try vector.field("canonical_manifest_utf8").string())
            XCTAssertEqual(.string(try V1Canonical.evidenceID(.object(fields))), expected)
        }
        XCTAssertEqual(try V1Canonical.text(.string("摄像头/\n\"\\\u{2028}")), "\"摄像头/\\n\\\"\\\\\u{2028}\"")
        XCTAssertEqual(V1Canonical.hash(Data([0xff,0xd8,0xff,0xd9])), "32461d5bd1773012acef0ba15636752949bd7c2ce50f9172159d9f56cf0dd9af")
    }
    @MainActor func testPermissionMappingAndAvailabilityRevisionRetainsSupport() throws {
        XCTAssertEqual(NativeStillImageCapture.permissionFailure(.denied), .permissionDenied)
        XCTAssertEqual(NativeStillImageCapture.permissionFailure(.restricted), .permissionDenied)
        XCTAssertEqual(NativeStillImageCapture.permissionFailure(.notDetermined), .unavailable)
        XCTAssertNil(NativeStillImageCapture.permissionFailure(.authorized))
        let camera = FakeStillCamera(); let runtime = VisionRuntime(camera: camera); runtime.configured = true
        guard case .object(let before) = runtime.manifest else { return XCTFail() }
        camera.availability = .permissionDenied
        guard case .object(let after) = runtime.manifest, case .array(let caps) = after["capabilities"], case .object(let cap) = caps[0] else { return XCTFail() }
        XCTAssertEqual(cap["name"], .string("vision.observe")); XCTAssertEqual(cap["availability"], .string("TEMPORARILY_UNAVAILABLE"))
        XCTAssertEqual(after["revision"], .integer(1)); XCTAssertEqual(before["revision"], .integer(1))
        camera.availability = nil
        guard case .object(let restored) = runtime.manifest else { return XCTFail() }
        XCTAssertEqual(restored["revision"], .integer(1)); XCTAssertEqual(camera.calls, 0)
    }
    @MainActor func testDurableDuplicateNewRequestConflictAndFreshness() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let camera = FakeStillCamera(); let runtime = VisionRuntime(camera: camera); runtime.configured = true
        let command = request()
        let first = try await runtime.fulfill(command, body: "embodiment:phone", session: "runtime-session:one", identity: "client:device", root: directory)
        let duplicate = try await runtime.fulfill(command, body: "embodiment:phone", session: "runtime-session:one", identity: "client:device", root: directory)
        XCTAssertEqual(first, duplicate); XCTAssertEqual(camera.calls, 1)
        let reopened = VisionRuntime(camera: camera); reopened.configured = true
        let retained = try await reopened.fulfill(command, body: "embodiment:phone", session: "runtime-session:one", identity: "client:device", root: directory)
        XCTAssertEqual(retained, first); XCTAssertEqual(camera.calls, 1)
        let second = try await reopened.fulfill(request(), body: "embodiment:phone", session: "runtime-session:one", identity: "client:device", root: directory)
        XCTAssertNotEqual(second, first); XCTAssertEqual(camera.calls, 2)
        guard case .object(var changed) = command else { return XCTFail() }
        changed["arguments"] = .object(["extra": .bool(true)])
        let conflict = try await reopened.fulfill(.object(changed), body: "embodiment:phone", session: "runtime-session:one", identity: "client:device", root: directory)
        XCTAssertEqual(try code(conflict), "CONFLICT"); XCTAssertEqual(camera.calls, 2)
        camera.stale = true
        let stale = try await reopened.fulfill(request(), body: "embodiment:phone", session: "runtime-session:one", identity: "client:device", root: directory)
        XCTAssertEqual(try code(stale), "TIMEOUT")
    }
    @MainActor func testPendingReceiptDeadlineArgumentsFenceAndErrorsNeverRecapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let camera = FakeStillCamera(); let runtime = VisionRuntime(camera: camera); runtime.configured = true
        let pending = request()
        let command = try VisionCommand(pending, body: "embodiment:phone", session: "runtime-session:one")
        _ = try VisionReceipts(identity: "client:device\nembodiment:phone", root: directory).begin(command)
        let uncertain = try await runtime.fulfill(pending, body: "embodiment:phone", session: "runtime-session:one", identity: "client:device", root: directory)
        XCTAssertEqual(try code(uncertain), "INTERNAL_ERROR"); XCTAssertEqual(camera.calls, 0)
        let timeout = try await runtime.fulfill(request(expired: true), body: "embodiment:phone", session: "runtime-session:one", identity: "client:device", root: directory)
        XCTAssertEqual(try code(timeout), "TIMEOUT"); XCTAssertEqual(camera.calls, 0)
        XCTAssertThrowsError(try VisionCommand(request(), body: "embodiment:other", session: "runtime-session:one"))
        guard case .object(var arguments) = request() else { return XCTFail() }
        arguments["arguments"] = .object(["duration_ms": .integer(1)])
        let invalid = try await runtime.fulfill(.object(arguments), body: "embodiment:phone", session: "runtime-session:one", identity: "client:device", root: directory)
        XCTAssertEqual(try code(invalid), "INVALID_ARGUMENT"); XCTAssertEqual(camera.calls, 0)
        for failure in [VisionFailure.permissionDenied, .unavailable, .busy, .timeout, .internalError] {
            camera.failure = failure
            let result = try await runtime.fulfill(request(), body: "embodiment:phone", session: "runtime-session:one", identity: "client:device", root: directory)
            XCTAssertEqual(try code(result), failure.code)
        }
    }
    @MainActor private func code(_ value: JSONValue) throws -> String {
        guard case .object(let response) = value, case .object(let error) = response["error"] else { throw VisionFailure.internalError }
        return try error.field("code").string()
    }
    @MainActor func testConcurrentDuplicateWaitsForIdenticalResultAndSwiftVerifierArtifact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let camera = FakeStillCamera(); camera.delay = true
        let runtime = VisionRuntime(camera: camera); runtime.configured = true
        let command = request()
        async let first = runtime.fulfill(command, body: "embodiment:phone", session: "runtime-session:one", identity: "client:device", root: directory)
        try await Task.sleep(for: .milliseconds(10))
        async let duplicate = runtime.fulfill(command, body: "embodiment:phone", session: "runtime-session:one", identity: "client:device", root: directory)
        let results = try await (first, duplicate)
        XCTAssertEqual(results.0, results.1); XCTAssertEqual(camera.calls, 1)
        let image = CapturedImage(jpeg: Data([0xff,0xd8,0xff,0xd9]), capturedAt: try V1Time.parse("2026-10-05T04:00:01.000Z"), cameraID: "camera:example", width: 1, height: 1, captureDuration: 0, encodingDuration: 0)
        let result = try VisualEvidence.package(image, body: "embodiment:example-01", sequence: 1)
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try JSONEncoder().encode(result).write(to: documents.appendingPathComponent("swift-v1-observe.json"), options: .atomic)
    }

    @MainActor func testDeniedUnavailableUnauthorizedAndFenceSuppressCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let camera = FakeStillCamera(); let runtime = VisionRuntime(camera: camera)
        let unauthorized = try await runtime.fulfill(request(), body: "embodiment:phone", session: "runtime-session:one", identity: "client:device", root: directory)
        XCTAssertEqual(try code(unauthorized), "PERMISSION_DENIED"); XCTAssertEqual(camera.calls, 0)
        runtime.configured = true; camera.availability = .permissionDenied
        let denied = try await runtime.fulfill(request(), body: "embodiment:phone", session: "runtime-session:one", identity: "client:device", root: directory)
        XCTAssertEqual(try code(denied), "PERMISSION_DENIED"); XCTAssertEqual(camera.calls, 0)
        camera.availability = nil
        let ineffective = try await runtime.fulfill(request(), body: "embodiment:phone", session: "runtime-session:one", identity: "client:device", root: directory, effective: false)
        XCTAssertEqual(try code(ineffective), "TEMPORARILY_UNAVAILABLE"); XCTAssertEqual(camera.calls, 0)
        let fenced = try await runtime.fulfill(request(), body: "embodiment:phone", session: "runtime-session:one", identity: "client:device", root: directory, active: { false })
        XCTAssertEqual(try code(fenced), "CONFLICT"); XCTAssertEqual(camera.calls, 0)
        runtime.mediaLimit = 4
        let oversized = try await runtime.fulfill(request(), body: "embodiment:phone", session: "runtime-session:one", identity: "client:device", root: directory)
        XCTAssertEqual(try code(oversized), "INVALID_ARGUMENT")
    }

    @MainActor func testManifestUpdatesIncrementOnceAndReconnectStartsAtOne() async throws {
        let camera = FakeStillCamera(); let runtime = VisionRuntime(camera: camera); runtime.configured = true
        let store = try ProvisioningMemoryStore()
        var metadata = try V1ProtocolTests.metadata(); metadata.embodimentID = "embodiment:phone"; metadata.visionObserveGranted = true
        store.metadata = metadata
        let peer = ManifestPeer()
        let connection = ConnectionController(store: store, purpose: .device, automaticallyConnect: false, manifestProvider: { runtime.manifest }, factory: { _, _, _ in peer })
        connection.connect()
        for _ in 0..<100 { if connection.displayedState == .connected { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(connection.session?.manifestRevision, 1)
        camera.availability = .permissionDenied
        for _ in 0..<100 { if connection.session?.manifestRevision == 2 { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(connection.session?.manifestRevision, 2); XCTAssertEqual(connection.session?.effectiveCapabilities, [])
        camera.availability = nil
        for _ in 0..<100 { if connection.session?.manifestRevision == 3 { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(connection.session?.manifestRevision, 3); XCTAssertEqual(connection.session?.effectiveCapabilities, ["vision.observe"])
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(connection.session?.manifestRevision, 3)
        connection.setForeground(false); connection.setForeground(true)
        for _ in 0..<100 { if connection.displayedState == .connected { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(connection.session?.manifestRevision, 1)
        let registrations = await peer.registrations
        XCTAssertEqual(registrations, [1,1])
        await connection.disconnect()
    }

    @MainActor func testRetainedBodyIsIndependentOfCredentialAndCannotSwitchDuringUpgrade() throws {
        let service = "HomeCortex.VisionTests." + UUID().uuidString
        let device = KeychainCredentialStore(service: service, purpose: .device)
        let caller = KeychainCredentialStore(service: service)
        try device.storeRetainedEmbodiment("embodiment:phone")
        try device.forget()
        XCTAssertNil(try device.load())
        XCTAssertEqual(try KeychainCredentialStore(service: service, purpose: .device).retainedEmbodiment(), "embodiment:phone")
        XCTAssertThrowsError(try device.storeRetainedEmbodiment("embodiment:other"))
        XCTAssertThrowsError(try caller.storeRetainedEmbodiment("embodiment:phone"))
        XCTAssertNil(try caller.retainedEmbodiment())
    }

    @MainActor func testNarrowVisionGrantAndBoundEnrollment() throws {
        let body = "embodiment:phone"
        let session = JSONValue.object(["embodiment_id": .string(body), "verb": .string("session"), "capability": .null])
        let vision = JSONValue.object(["embodiment_id": .string(body), "verb": .string("receive"), "capability": .string("vision.observe")])
        XCTAssertTrue(try V1Grants.visionObserve(.array([session,vision]), body: body, purpose: .device))
        XCTAssertThrowsError(try V1Grants.visionObserve(.array([session,vision]), body: body, purpose: .caller))
        XCTAssertThrowsError(try V1Grants.visionObserve(.array([session,vision,vision]), body: body, purpose: .device))
        XCTAssertThrowsError(try V1Grants.visionObserve(.array([session, .object(["embodiment_id": .string(body), "verb": .string("receive"), "capability": .string("vision.observe_clip")])]), body: body, purpose: .device))
    }
}

private actor ManifestPeer: V1Transport {
    var revision: Int64 = 0
    var effective: [String] = []
    var registrations: [Int64] = []
    func send(path: String, body: JSONValue?) async throws -> JSONValue {
        if path == "/client-interface/v1/discovery" { return try V1ProtocolTests.fixture("discovery") }
        guard case .object(let raw) = body else { throw ClientFailure.invalidResponse }
        let operation = try raw.field("operation").string()
        if operation == "session.register" || operation == "session.capabilities" {
            guard case .object(let args) = raw["arguments"], case .object(let manifest) = args["manifest"], case .integer(let incoming) = manifest["revision"], case .array(let caps) = manifest["capabilities"], case .object(let cap) = caps.first else { throw ClientFailure.invalidResponse }
            if operation == "session.register" {
                XCTAssertEqual(incoming, 1); registrations.append(incoming)
            } else { XCTAssertEqual(incoming, revision + 1) }
            revision = incoming; effective = cap["availability"] == .string("AVAILABLE") ? ["vision.observe"] : []
        }
        let request = V1Request(operation: operation, clientID: "client:apple-test", version: "test")
        var response = try V1ProtocolTests.softwareResponse(request: request)
        response["request_id"] = raw["request_id"]; response["target"] = raw["target"]
        guard case .object(var view) = response["result"] else { throw ClientFailure.invalidResponse }
        view["embodiment_id"] = .string("embodiment:phone"); view["manifest_revision"] = .integer(revision)
        view["effective_capabilities"] = .array(effective.map(JSONValue.string))
        response["result"] = .object(view)
        return .object(response)
    }
}
