import XCTest
@testable import HomeCortex

final class PhysicalConversationTests: XCTestCase {
    @MainActor private func waitUntil(seconds: Int = 180, _ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(Double(seconds))
        while Date() < end {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ChatFailure.timeout
    }

    @MainActor
    func testRealPhoneCanonicalConversationAndForegroundReconnect() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the provisioned physical phone and real backend.")
        #else
        let connection = AppRuntime.connection
        let credential = try XCTUnwrap(connection.credential, "Phone must retain its provisioned credential")
        XCTAssertEqual(connection.provisioning, .provisioned)
        connection.setForeground(true)
        if connection.displayedState != .connected { connection.connect() }
        try await waitUntil(seconds: 45) { connection.displayedState == .connected }
        let chat = AppRuntime.chat
        if chat.state != .ready { chat.load() }
        try await waitUntil { chat.state == .ready || { if case .failed = chat.state { return true }; return false }() }
        XCTAssertEqual(chat.state, .ready)
        let conversationID = try XCTUnwrap(chat.conversationID)
        let questions = ["我是谁", "你是谁", "我岳父是谁", "我家里都有谁", "Who am I?", "Who are you?", "Who is in my household?"]
        for question in questions {
            chat.draft = question
            XCTAssertTrue(chat.canSend)
            chat.send()
            try await waitUntil { chat.state != .sending }
            XCTAssertEqual(chat.state, .ready, "Real conversation failed for \(question)")
            let answer = try XCTUnwrap(chat.messages.last)
            XCTAssertEqual(answer.role, .assistant)
            XCTAssertEqual(answer.state, .complete)
            XCTAssertFalse(answer.content.isEmpty)
            if question == "我是谁" { XCTAssertTrue(answer.content.contains("匡健"), answer.content) }
            if question == "你是谁" { XCTAssertTrue(answer.content.contains("老管家"), answer.content) }
            XCTContext.runActivity(named: question) { activity in
                let attachment = XCTAttachment(string: answer.content)
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
        }
        let reply = chat.messages.last?.content
        chat.load()
        try await waitUntil { chat.state != .loading }
        XCTAssertEqual(chat.state, .ready)
        XCTAssertEqual(chat.messages.last?.content, reply, "Server history must persist streamed answer")
        connection.setForeground(false)
        chat.connectionChanged(connected: false)
        XCTAssertNotEqual(connection.displayedState, .connected)
        chat.draft = "reconnect check"
        XCTAssertFalse(chat.canSend)
        connection.setForeground(true)
        try await waitUntil(seconds: 45) { connection.displayedState == .connected }
        chat.connectionChanged(connected: true)
        try await waitUntil { chat.state != .loading }
        XCTAssertEqual(chat.state, .ready)
        XCTAssertEqual(chat.conversationID, conversationID)
        XCTAssertEqual(connection.credential?.clientID, credential.clientID)
        let access = try connection.conversationAccess()
        let restored = try await access.transport.history(id: conversationID, sessionID: access.sessionID)
        XCTAssertEqual(restored.history.last?.content, reply)
        #endif
    }
}
