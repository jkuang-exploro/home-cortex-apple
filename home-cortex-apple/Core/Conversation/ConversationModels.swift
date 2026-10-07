import Foundation

enum ChatFailure: Error, Equatable, LocalizedError, Sendable {
    case notConnected, authentication, timeout, unavailable, invalidResponse, conversation, interrupted, notFound
    var errorDescription: String? {
        switch self {
        case .notConnected: "Connect to Home Cortex before sending."
        case .authentication: "Conversation access was denied. Check the connection and operator-issued conversation permission."
        case .timeout: "The request timed out. Check history before sending again."
        case .unavailable: "Home Cortex is unavailable. Check history after reconnecting."
        case .invalidResponse: "Home Cortex returned an invalid conversation response."
        case .conversation: "The conversation could not finish. Check history before sending again."
        case .interrupted: "Response stopped. A partial reply may be saved on the server."
        case .notFound: "This conversation is no longer available."
        }
    }
    static func map(_ error: any Error) -> ChatFailure {
        if let failure = error as? ChatFailure { return failure }
        if error is CancellationError { return .interrupted }
        if let error = error as? URLError {
            if error.code == .timedOut { return .timeout }
            if error.code == .cancelled { return Task.isCancelled ? .interrupted : .authentication }
            if [.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                .serverCertificateNotYetValid, .clientCertificateRequired, .clientCertificateRejected,
                .secureConnectionFailed, .userAuthenticationRequired, .userCancelledAuthentication].contains(error.code) { return .authentication }
            return .unavailable
        }
        if error is DecodingError { return .invalidResponse }
        return .conversation
    }
}

enum MessageRole: String, Codable, Sendable { case user, assistant }
enum MessageState: Equatable, Sendable {
    case pending, sent, receiving, complete
    case failed(ChatFailure, safeToRetry: Bool)
}
struct ChatMessage: Identifiable, Equatable, Sendable {
    let id: String
    let role: MessageRole
    var content: String
    var state: MessageState
}

struct ConversationDocument: Decodable, Sendable {
    struct Message: Decodable, Sendable {
        let id: String
        let role: MessageRole
        let content: String
    }
    let id: String
    let object: String
    let agent_id: String?
    let agent_entity_id: String?
    let active_embodiment_id: String?
    let messages: [Message]

    static func decode(_ data: Data) throws -> ConversationDocument {
        guard data.count <= 2_097_152 else { throw ChatFailure.invalidResponse }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard validID(value.id), value.object == "conversation", value.agent_id == "steward",
              value.agent_entity_id == "agent:butler",
              value.active_embodiment_id == nil || value.active_embodiment_id?.range(of: "^embodiment:[A-Za-z0-9_-]+(:[A-Za-z0-9_-]+)*$", options: .regularExpression) != nil,
              value.messages.count <= 10_000,
              Set(value.messages.map(\.id)).count == value.messages.count,
              value.messages.allSatisfy({ validID($0.id) && $0.content.utf8.count <= 1_048_576 }) else {
            throw ChatFailure.invalidResponse
        }
        return value
    }
    static func validID(_ id: String) -> Bool {
        id.count <= 128 && id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }
    var history: [ChatMessage] {
        messages.map { ChatMessage(id: $0.id, role: $0.role, content: $0.content,
            state: $0.role == .user ? .sent : .complete) }
    }
}

struct ConversationSend: Encodable, Sendable {
    let content: String
    let stream = true
}

enum ConversationEvent: Equatable, Sendable { case delta(String), complete }

// Consume SSE records after byte framing has preserved their blank separators.
struct ConversationSSEParser {
    private var dataLines: [String] = []
    private var recordBytes = 0
    private var completionID: String?
    private var finished = false
    private(set) var done = false

    mutating func line(_ line: String) throws -> [ConversationEvent] {
        guard !done else { throw ChatFailure.invalidResponse }
        recordBytes += line.utf8.count
        guard recordBytes <= 131_072 else { throw ChatFailure.invalidResponse }
        if !line.isEmpty {
            if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.hasPrefix(" ") { value.removeFirst() }
                dataLines.append(value)
            }
            return []
        }
        defer { dataLines.removeAll(); recordBytes = 0 }
        guard !dataLines.isEmpty else { return [] }
        let record = dataLines.joined(separator: "\n")
        if record == "[DONE]" {
            guard finished else { throw ChatFailure.invalidResponse }
            done = true
            return [.complete]
        }
        guard let data = record.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let root) = value else { throw ChatFailure.invalidResponse }
        if root["error"] != nil { throw ChatFailure.conversation }
        guard !finished, root["object"] == .string("chat.completion.chunk"),
              case .string(let id) = root["id"], id.hasPrefix("chatcmpl-"),
              case .array(let choices) = root["choices"], choices.count == 1,
              case .object(let choice) = choices[0], choice["index"] == .integer(0),
              case .object(let delta) = choice["delta"] else { throw ChatFailure.invalidResponse }
        if let completionID, completionID != id { throw ChatFailure.invalidResponse }
        completionID = id
        if let role = delta["role"], role != .string("assistant") { throw ChatFailure.invalidResponse }
        if choice["finish_reason"] == .string("stop") { finished = true }
        else if let reason = choice["finish_reason"], reason != .null { throw ChatFailure.conversation }
        if let content = delta["content"] {
            guard case .string(let text) = content else { throw ChatFailure.invalidResponse }
            return text.isEmpty ? [] : [.delta(text)]
        }
        return []
    }
    func validateEnd() throws { guard done else { throw ChatFailure.invalidResponse } }
}

// Foundation's AsyncBytes.lines omits empty lines, including SSE's event
// separators. Frame bytes directly, decoding UTF-8 only once a line is complete.
struct ConversationSSEDecoder {
    private var parser = ConversationSSEParser()
    private var buffer = Data()
    private var afterCR = false
    private var byteCount = 0
    var done: Bool { parser.done }

    mutating func byte(_ byte: UInt8) throws -> [ConversationEvent] {
        byteCount += 1
        guard byteCount <= 1_048_576 else { throw ChatFailure.invalidResponse }
        if afterCR {
            afterCR = false
            if byte == 10 { return [] } // CRLF is one terminator.
        }
        if byte == 10 || byte == 13 {
            afterCR = byte == 13
            guard let line = String(data: buffer, encoding: .utf8) else { throw ChatFailure.invalidResponse }
            buffer.removeAll(keepingCapacity: true)
            return try parser.line(line)
        }
        guard buffer.count < 131_072 else { throw ChatFailure.invalidResponse }
        buffer.append(byte)
        return []
    }
    func validateEnd() throws {
        guard buffer.isEmpty else { throw ChatFailure.invalidResponse }
        try parser.validateEnd()
    }
}
