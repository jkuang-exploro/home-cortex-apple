import XCTest
@testable import HomeCortex

private let transcript = Data("""
{"id":"thread_123","object":"conversation","agent_id":"steward","agent_entity_id":"agent:butler","active_embodiment_id":null,"messages":[{"id":"greeting","role":"assistant","content":"先生，您回来了。"}]}
""".utf8)

private actor ChatStub: ConversationTransport {
    enum Mode { case success, timeout, suspended, empty }
    var mode = Mode.success
    var sends: [String] = []
    var histories: [String] = []
    func setMode(_ value: Mode) { mode = value }
    func history(id: String, sessionID: String) throws -> ConversationDocument {
        histories.append(id)
        return try ConversationDocument.decode(transcript)
    }
    func selectOrCreate(sessionID: String) throws -> ConversationDocument { try ConversationDocument.decode(transcript) }
    func stream(id: String, content: String, sessionID: String,
                receive: @escaping @Sendable (ConversationEvent) async throws -> Void) async throws {
        sends.append(content)
        switch mode {
        case .timeout: throw URLError(.timedOut)
        case .suspended: try await Task.sleep(for: .seconds(60))
        case .empty: try await receive(.complete)
        case .success:
            try await receive(.delta("您是"))
            try await receive(.delta("匡健。 👨‍👩‍👧‍👦"))
            try await receive(.complete)
        }
    }
}

final class ConversationTests: XCTestCase {
    func testCanonicalSchemasPreserveOriginalUnicode() throws {
        for text in ["我是谁", "你是谁", "我岳父是谁", "我家里都有谁", "Who am I?", "Who are you?", "Who is in my household?", "  中英 English\n👨‍👩‍👧‍👦  "] {
            let encoded = try JSONEncoder().encode(ConversationSend(content: text))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(object["content"] as? String, text)
            XCTAssertEqual(object["stream"] as? Bool, true)
        }
        let document = try ConversationDocument.decode(transcript)
        XCTAssertEqual(document.id, "thread_123")
        XCTAssertEqual(document.history.first?.content, "先生，您回来了。")
        XCTAssertEqual(document.history.first?.state, .complete)
        for invalid in ["agent:other", "embodiment:phone"] {
            let data = Data(String(decoding: transcript, as: UTF8.self)
                .replacingOccurrences(of: invalid.hasPrefix("agent") ? "agent:butler" : "null", with: invalid.hasPrefix("agent") ? invalid : "\"\(invalid)\"").utf8)
            XCTAssertThrowsError(try ConversationDocument.decode(data))
        }
        XCTAssertThrowsError(try ConversationDocument.decode(Data("{}".utf8)))
    }

    func testRealSSEFramingCompletionAndFailure() throws {
        var parser = ConversationSSEParser()
        XCTAssertEqual(try parser.line(": padding"), [])
        XCTAssertEqual(try parser.line(""), [])
        func record(_ delta: String, finish: String = "null") -> String {
            "data: {\"id\":\"chatcmpl-123\",\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":\(delta),\"finish_reason\":\(finish)}]}"
        }
        _ = try parser.line(record("{\"content\":\"您是匡健。🌏\"}"))
        XCTAssertEqual(try parser.line(""), [.delta("您是匡健。🌏")])
        XCTAssertThrowsError(try parser.validateEnd())
        _ = try parser.line(record("{}", finish: "\"stop\""))
        _ = try parser.line("")
        _ = try parser.line("data: [DONE]")
        XCTAssertEqual(try parser.line(""), [.complete])
        try parser.validateEnd()
        var malformed = ConversationSSEParser()
        _ = try malformed.line("data: [DONE]")
        XCTAssertThrowsError(try malformed.line(""))
        var failed = ConversationSSEParser()
        _ = try failed.line("data: {\"error\":{\"code\":\"internal_server_error\",\"message\":\"sensitive traceback\"}}")
        XCTAssertThrowsError(try failed.line("")) { XCTAssertEqual($0 as? ChatFailure, .conversation) }
        var oversized = ConversationSSEParser()
        XCTAssertThrowsError(try oversized.line(String(repeating: "a", count: 131_073)))
    }

    @MainActor private func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Conversation state did not settle")
    }
    @MainActor
    func testSendLifecycleReconnectAndPersistentConversationSelection() async throws {
        let stub = ChatStub()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        var connected = true
        var session = "runtime-session:first"
        let access: @MainActor () throws -> ConversationAccess = {
            guard connected else { throw ChatFailure.notConnected }
            return ConversationAccess(clientID: "client:test", sessionID: session,
                origin: URL(string: "https://home-cortex-0:8443")!, transport: stub)
        }
        let controller = ConversationController(defaults: defaults, isConnected: { connected }, access: access)
        controller.load()
        try await settle { controller.state == .ready }
        controller.draft = "  我是谁\n"
        XCTAssertTrue(controller.canSend)
        controller.send()
        XCTAssertEqual(controller.state, .sending)
        controller.send() // No double-tap duplicate.
        try await settle { controller.state == .ready }
        let sent = await stub.sends
        XCTAssertEqual(sent, ["  我是谁\n"])
        XCTAssertEqual(controller.messages.last?.content, "您是匡健。 👨‍👩‍👧‍👦")
        connected = false
        controller.connectionChanged(connected: false)
        controller.draft = "Who am I?"
        XCTAssertFalse(controller.canSend)
        controller.send()
        guard case .failed(.notConnected, safeToRetry: true) = controller.messages.last?.state else { return XCTFail("Expected safe local failure") }
        let offlineID = controller.messages.last!.id
        connected = true
        controller.retry(offlineID)
        try await settle { controller.state == .ready }
        session = "runtime-session:second"
        let reopened = ConversationController(defaults: defaults, access: access)
        reopened.load()
        try await settle { reopened.state == .ready }
        XCTAssertEqual(reopened.conversationID, "thread_123")
        let histories = await stub.histories
        XCTAssertEqual(histories, ["thread_123"])
    }
    @MainActor
    func testTimeoutAndCancellationNeverAutomaticallyResend() async throws {
        let stub = ChatStub()
        let controller = ConversationController(defaults: UserDefaults(suiteName: UUID().uuidString)!) {
            ConversationAccess(clientID: "client:test", sessionID: "runtime-session:test",
                origin: URL(string: "https://home-cortex-0:8443")!, transport: stub)
        }
        controller.load()
        try await settle { controller.state == .ready }
        await stub.setMode(.timeout)
        controller.draft = "我是谁"
        controller.send()
        try await settle { controller.state == .failed(.timeout) }
        guard case .failed(.timeout, safeToRetry: false) = controller.messages.first(where: { $0.role == .user })?.state else { return XCTFail("Uncertain send must not retry") }
        controller.retry(controller.messages[1].id)
        let sends = await stub.sends
        XCTAssertEqual(sends.count, 1)
        controller.load()
        try await settle { controller.state == .ready }
        await stub.setMode(.suspended)
        controller.draft = "Who am I?"
        controller.send()
        controller.connectionChanged(connected: false)
        XCTAssertEqual(controller.state, .failed(.interrupted))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.state, .failed(.interrupted))
        XCTAssertEqual(ChatFailure.map(URLError(.timedOut)), .timeout)
        XCTAssertEqual(ChatFailure.map(URLError(.serverCertificateUntrusted)), .authentication)
        XCTAssertEqual(ChatFailure.map(URLError(.notConnectedToInternet)), .unavailable)
    }
    @MainActor
    func testEmptyCompletedResponseFailsTruthfully() async throws {
        let stub = ChatStub()
        await stub.setMode(.empty)
        let controller = ConversationController(defaults: UserDefaults(suiteName: UUID().uuidString)!) {
            ConversationAccess(clientID: "client:test", sessionID: "runtime-session:test",
                origin: URL(string: "https://home-cortex-0:8443")!, transport: stub)
        }
        controller.load()
        try await settle { controller.state == .ready }
        controller.draft = "我是谁"
        controller.send()
        try await settle { controller.state == .failed(.invalidResponse) }
        XCTAssertEqual(controller.messages.last?.state, .failed(.invalidResponse, safeToRetry: false))
    }
}
