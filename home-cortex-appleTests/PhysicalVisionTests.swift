import XCTest
import Security
@testable import HomeCortex

final class PhysicalVisionTests: XCTestCase {
    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<1200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ChatFailure.timeout
    }
    @MainActor func testRealCallerActivePhoneObservationAndDuplicateAcknowledgment() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical rear camera, upgraded DEVICE and explicit camera permission required.")
        #else
        let caller = AppRuntime.connection
        let phone = AppRuntime.embodiment
        guard phone.connection.credential?.visionObserveGranted == true, phone.runtimeEnabled else {
            throw XCTSkip("Import the explicit vision.observe replacement DEVICE invitation first.")
        }
        guard phone.vision.camera.availability == nil else { throw XCTSkip("Grant camera permission explicitly on the phone first.") }
        caller.setForeground(true); phone.setForeground(true)
        try await wait { caller.displayedState == .connected && phone.isOnline && phone.connection.session?.effectiveCapabilities == ["vision.observe"] }
        let callerMetadata = try XCTUnwrap(caller.credential)
        let deviceMetadata = try XCTUnwrap(phone.connection.credential)
        XCTAssertNil(callerMetadata.embodimentID)
        XCTAssertNotEqual(callerMetadata.clientID, deviceMetadata.clientID)
        for (purpose, credential) in [(CredentialPurpose.caller, callerMetadata), (.device, deviceMetadata)] {
            let identity = try KeychainCredentialStore(purpose: purpose).identity(for: credential)
            var key: SecKey?
            XCTAssertEqual(SecIdentityCopyPrivateKey(identity.identity, &key), errSecSuccess)
            XCTAssertEqual((SecKeyCopyAttributes(try XCTUnwrap(key)) as? [String: Any])?[kSecAttrTokenID as String] as? String, kSecAttrTokenIDSecureEnclave as String)
        }
        let chat = AppRuntime.chat
        chat.load(); try await wait { chat.state != .loading }
        XCTAssertEqual(chat.state, .ready)
        chat.draft = "我是谁"; chat.send(); try await wait { chat.state != .sending }
        XCTAssertEqual(chat.state, .ready)
        XCTAssertFalse(try XCTUnwrap(chat.messages.last).content.isEmpty)
        let body = try XCTUnwrap(phone.embodimentID)
        chat.selectEmbodiment(body); try await wait { chat.state != .loading }
        XCTAssertEqual(chat.state, .ready); XCTAssertEqual(chat.activeEmbodimentID, body)
        let initial = phone.vision.captures
        chat.draft = "你现在能看到什么？"; chat.send(); try await wait { chat.state != .sending }
        XCTAssertEqual(chat.state, .ready)
        XCTAssertGreaterThan(phone.vision.captures, initial)
        XCTAssertNotNil(phone.vision.lastEvidenceID)
        XCTAssertNil(phone.vision.lastError)
        let answer = try XCTUnwrap(chat.messages.last)
        XCTAssertEqual(answer.role, .assistant); XCTAssertEqual(answer.state, .complete)
        XCTAssertFalse(answer.content.isEmpty)
        let raw = try XCTUnwrap(phone.vision.lastCommand)
        guard case .object(let command) = raw, case .object(let target) = command["target"] else { return XCTFail() }
        let session = try target.field("session_id").string()
        let beforeReplay = phone.vision.captures
        let replay = try await phone.vision.fulfill(raw, body: body, session: session, identity: deviceMetadata.clientID)
        XCTAssertEqual(phone.vision.captures, beforeReplay)
        let acknowledgment = try await phone.connection.deviceTransport().send(path: "/client-interface/v1/messages", body: replay)
        XCTAssertEqual(acknowledgment, .null)
        print("Physical vision evidence: \(phone.vision.lastEvidenceID ?? "missing"); \(phone.vision.lastTiming ?? "no timing")")
        print("Physical vision answer: \(answer.content)")
        #endif
    }
}
