import Foundation

struct VisionCommand: Sendable {
    let id: String
    let sentAt: Date
    let deadline: Date
    let value: JSONValue
    let target: JSONValue
    init(_ value: JSONValue, body: String, session: String) throws {
        let o = try value.object(required: ["protocol_version", "schema_name", "schema_version", "message_id", "sent_at", "request_id", "target", "operation", "arguments", "deadline_at"], optional: ["extensions"])
        guard try o.field("protocol_version").string() == "1.0", o["schema_name"] == .string("hc.request"),
              o["schema_version"] == .integer(1), o["operation"] == .string("vision.observe") else { throw VisionFailure.invalidArgument }
        func uuid(_ v: JSONValue) throws -> String {
            let text = try v.string()
            guard text.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil else { throw VisionFailure.invalidArgument }
            return text
        }
        id = try uuid(o.field("request_id")); _ = try uuid(o.field("message_id"))
        target = try o.field("target")
        let t = try target.object(required: ["embodiment_id", "session_id"])
        guard t["embodiment_id"] == .string(body), t["session_id"] == .string(session) else { throw VisionFailure.staleSession }
        if let extensions = o["extensions"] {
            guard case .object(let fields) = extensions, fields.count <= 32,
                  fields.keys.allSatisfy({ $0.range(of: "^[a-z][a-z0-9_]*(\\.[a-z][a-z0-9_]*)+$", options: .regularExpression) != nil }) else { throw VisionFailure.invalidArgument }
        }
        sentAt = try V1Time.parse(o.field("sent_at").string())
        deadline = try V1Time.parse(o.field("deadline_at").string())
        guard deadline > sentAt else { throw VisionFailure.invalidArgument }
        self.value = value
    }
    func reply(result: JSONValue? = nil, error: VisionFailure? = nil, now: Date = Date()) -> JSONValue {
        var response: [String: JSONValue] = [
            "protocol_version": .string("1.0"), "schema_name": .string("hc.response"), "schema_version": .integer(1),
            "message_id": .string(UUID().uuidString.lowercased()), "sent_at": .string(V1Time.format(now)),
            "request_id": .string(id), "target": target, "operation": .string("vision.observe"), "completed_at": .string(V1Time.format(now)),
            "status": .string(error == nil ? "SUCCEEDED" : "FAILED")
        ]
        if let error { response["error"] = error.wire } else { response["result"] = result ?? .object([:]) }
        return .object(response)
    }
}

/// Fsync/atomic protected receipts are committed before capture and before upload.
/// A crash with a pending receipt is uncertain and must never cause another photo.
@MainActor final class VisionReceipts {
    private let directory: URL
    init(identity: String, root: URL? = nil) throws {
        let base = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        directory = base.appendingPathComponent("V1Vision/" + V1Canonical.hash(Data(identity.utf8)), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication, .posixPermissions: 0o700])
    }
    private func url(_ id: String) -> URL { directory.appendingPathComponent(id + ".json") }
    func begin(_ command: VisionCommand, now: Date = Date()) throws -> (Bool, JSONValue?) {
        let file = url(command.id)
        if FileManager.default.fileExists(atPath: file.path) {
            let record = try JSONValue.decode(Data(contentsOf: file), maxBytes: 2_097_152).object(required: ["request", "retain_until"], optional: ["response"])
            guard record["request"] == command.value else { throw VisionFailure.conflict }
            return (false, record["response"])
        }
        guard now < command.deadline else { throw VisionFailure.timeout }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        for file in files {
            if let data = try? Data(contentsOf: file), let record = try? JSONValue.decode(data, maxBytes: 2_097_152).object(required: ["request", "retain_until"], optional: ["response"]),
               let text = try? record.field("retain_until").string(), let expires = try? V1Time.parse(text), expires < now { try FileManager.default.removeItem(at: file) }
        }
        let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        guard remaining.count < 128, try remaining.reduce(0, { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }) < 64 * 1024 * 1024 else { throw VisionFailure.busy }
        try write(command, response: nil)
        return (true, nil)
    }
    func finish(_ command: VisionCommand, response: JSONValue) throws { try write(command, response: response) }
    private func write(_ command: VisionCommand, response: JSONValue?) throws {
        var record: [String: JSONValue] = ["request": command.value, "retain_until": .string(V1Time.format(command.deadline.addingTimeInterval(86400)))]
        if let response { record["response"] = response }
        let data = try JSONEncoder().encode(JSONValue.object(record))
        try data.write(to: url(command.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(command.id).path)
        let handle = try FileHandle(forWritingTo: url(command.id)); defer { try? handle.close() }
        try handle.synchronize()
    }
}
