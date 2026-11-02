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

/// Protected receipt metadata and temporary JPEGs share the existing bounded receipt directory.
/// Commit metadata before deleting acknowledged bytes; uncertain captures never recapture.
actor VisionReceipts {
    nonisolated let directory: URL
    private let remove: @Sendable (URL) throws -> Void
    init(identity: String, root: URL? = nil, remove: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) throws {
        self.remove = remove
        let base = try root ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        directory = base.appendingPathComponent("V1Vision/" + V1Canonical.hash(Data(identity.utf8)), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o700])
        var url = directory.deletingLastPathComponent(), values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        url = directory; try url.setResourceValues(values)
    }
    private func url(_ id: String, _ ext: String = "json") -> URL { directory.appendingPathComponent(id + "." + ext) }
    private func read(_ file: URL) throws -> [String: JSONValue] {
        guard try (file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 2_097_152 else { throw VisionFailure.busy }
        return try JSONValue.decode(Data(contentsOf: file), maxBytes: 2_097_152).object(required: ["request", "retain_until"], optional: ["response", "acknowledged"])
    }
    private func compact(_ response: JSONValue) -> JSONValue {
        guard case .object(var fields) = response, case .object(var result) = fields["result"] else { return response }
        result.removeValue(forKey: "media_base64"); fields["result"] = .object(result); return .object(fields)
    }
    private func write(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; try handle.synchronize()
    }
    private func removeMedia(_ id: String) throws {
        let file = url(id,"jpg")
        if FileManager.default.fileExists(atPath: file.path) { try remove(file) }
    }
    func reap(now: Date = Date()) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        for file in files where file.pathExtension == "json" {
            let record = try read(file)
            if try V1Time.parse(record.field("retain_until").string()) <= now {
                try removeMedia(file.deletingPathExtension().lastPathComponent); try FileManager.default.removeItem(at: file)
            } else if record["acknowledged"] == .bool(true) { try removeMedia(file.deletingPathExtension().lastPathComponent) }
        }
    }
    func begin(_ command: VisionCommand, now: Date = Date()) throws -> (Bool, JSONValue?) {
        try reap(now: now)
        if FileManager.default.fileExists(atPath: url(command.id).path) {
            var record = try read(url(command.id))
            guard record["request"] == command.value else { throw VisionFailure.conflict }
            if case .object(let response) = record["response"], case .object(let result) = response["result"], result["media_base64"] != nil {
                try finish(command, response: .object(response)); record = try read(url(command.id)) // Migrate legacy inline JPEGs.
            }
            guard case .object(var response) = record["response"] else { return (false,nil) }
            if record["acknowledged"] != .bool(true), case .object(var result) = response["result"] {
                guard try (url(command.id,"jpg").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= VisualEvidence.maxMediaBytes else { throw VisionFailure.busy }
                result["media_base64"] = .string(try Data(contentsOf: url(command.id,"jpg")).base64EncodedString()); response["result"] = .object(result)
            }
            return (false,.object(response))
        }
        guard now < command.deadline, now.timeIntervalSince(command.sentAt) < 86400 else { throw VisionFailure.timeout }
        let remaining = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        // Reserve the worst-case receipt plus JPEG before exposing the camera.
        guard remaining.filter({ $0.pathExtension == "json" }).count < 128,
              try remaining.reduce(0, { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }) <= 64*1024*1024-2_097_152 else { throw VisionFailure.busy }
        try write(JSONEncoder().encode(JSONValue.object(["request": command.value, "retain_until": .string(V1Time.format(min(command.deadline,now).addingTimeInterval(86400)))])), to: url(command.id))
        return (true,nil)
    }
    func finish(_ command: VisionCommand, response: JSONValue) throws {
        var record = try read(url(command.id))
        guard record["request"] == command.value else { throw VisionFailure.conflict }
        if case .object(let fields) = response, case .object(let result) = fields["result"], case .string(let base64) = result["media_base64"] {
            guard let jpeg = Data(base64Encoded: base64), jpeg.count <= VisualEvidence.maxMediaBytes else { throw VisionFailure.invalidArgument }
            try write(jpeg, to: url(command.id,"jpg"))
        }
        record["response"] = compact(response)
        try write(JSONEncoder().encode(JSONValue.object(record)), to: url(command.id))
    }
    func isAcknowledged(_ response: JSONValue) throws -> Bool {
        guard case .object(let fields) = response, case .string(let id) = fields["request_id"], UUID(uuidString: id) != nil else { throw VisionFailure.invalidArgument }
        guard FileManager.default.fileExists(atPath: url(id).path) else { return false }
        let record = try read(url(id)); return record["response"] == compact(response) && record["acknowledged"] == .bool(true)
    }
    func acknowledge(_ response: JSONValue) throws {
        guard case .object(let fields) = response, case .string(let id) = fields["request_id"], UUID(uuidString: id) != nil else { throw VisionFailure.invalidArgument }
        guard FileManager.default.fileExists(atPath: url(id).path) else { return }
        var record = try read(url(id))
        guard record["response"] == compact(response) else { return }
        record["acknowledged"] = .bool(true)
        try write(JSONEncoder().encode(JSONValue.object(record)), to: url(id)); try removeMedia(id)
    }
}
