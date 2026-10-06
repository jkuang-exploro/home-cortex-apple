import Foundation

enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(Int64), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    static func decode(_ data: Data) throws -> JSONValue {
        guard data.count <= 131_072 else { throw ClientFailure.invalidResponse }
        var scanner = JSONKeyScanner(bytes: Array(data))
        let value = try scanner.value(depth: 0)
        scanner.whitespace()
        guard scanner.offset == scanner.bytes.count else { throw ClientFailure.invalidResponse }
        return value
    }

    func object(required: Set<String>, optional: Set<String> = []) throws -> [String: JSONValue] {
        guard case .object(let v) = self, required.isSubset(of: Set(v.keys)),
              Set(v.keys).isSubset(of: required.union(optional)) else { throw ClientFailure.invalidResponse }
        return v
    }

    func string() throws -> String {
        guard case .string(let v) = self, !v.isEmpty, v.count <= 32_768 else { throw ClientFailure.invalidResponse }
        return v
    }

    func integer(minimum: Int64 = 0) throws -> Int64 {
        guard case .integer(let v) = self, v >= minimum, v <= 9_007_199_254_740_991 else { throw ClientFailure.invalidResponse }
        return v
    }

    func strings() throws -> [String] {
        guard case .array(let v) = self, v.count <= 128 else { throw ClientFailure.invalidResponse }
        return try v.map { try $0.string() }
    }
}

// JSONDecoder accepts duplicate object keys. Reject them (including escaped aliases)
// before decoding, as required by the frozen V1 closed-object profile.
private struct JSONKeyScanner {
    let bytes: [UInt8]
    var offset = 0
    mutating func whitespace() {
        while offset < bytes.count, [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 }
    }
    mutating func consume(_ byte: UInt8) throws {
        whitespace()
        guard offset < bytes.count, bytes[offset] == byte else { throw ClientFailure.invalidResponse }
        offset += 1
    }
    mutating func text() throws -> String {
        whitespace()
        let start = offset
        try consume(34)
        while offset < bytes.count {
            let b = bytes[offset]
            offset += 1
            if b == 34 {
                guard let value = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) else {
                    throw ClientFailure.invalidResponse
                }
                return value
            }
            if b == 92 { offset += 1 }
        }
        throw ClientFailure.invalidResponse
    }
    mutating func value(depth: Int) throws -> JSONValue {
        whitespace()
        guard depth < 64, offset < bytes.count else { throw ClientFailure.invalidResponse }
        if bytes[offset] == 123 {
            offset += 1
            whitespace()
            if offset < bytes.count, bytes[offset] == 125 { offset += 1; return .object([:]) }
            var fields: [String: JSONValue] = [:]
            while true {
                let key = try text()
                guard fields[key] == nil else { throw ClientFailure.invalidResponse }
                try consume(58)
                fields[key] = try value(depth: depth + 1)
                whitespace()
                guard offset < bytes.count else { throw ClientFailure.invalidResponse }
                if bytes[offset] == 125 { offset += 1; return .object(fields) }
                try consume(44)
            }
        } else if bytes[offset] == 91 {
            offset += 1
            whitespace()
            if offset < bytes.count, bytes[offset] == 93 { offset += 1; return .array([]) }
            var values: [JSONValue] = []
            while true {
                values.append(try value(depth: depth + 1))
                whitespace()
                guard offset < bytes.count else { throw ClientFailure.invalidResponse }
                if bytes[offset] == 93 { offset += 1; return .array(values) }
                try consume(44)
            }
        } else if bytes[offset] == 34 { return .string(try text()) }
        else {
            let start = offset
            while offset < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[offset]) { offset += 1 }
            guard offset > start else { throw ClientFailure.invalidResponse }
            let raw = Data(bytes[start..<offset])
            let token = String(decoding: raw, as: UTF8.self)
            switch token {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default:
                guard let number = try? JSONDecoder().decode(Double.self, from: raw), number.isFinite else { throw ClientFailure.invalidResponse }
                if !token.contains("."), !token.lowercased().contains("e"), let integer = Int64(token) { return .integer(integer) }
                return .number(number)
            }
        }
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func field(_ name: String) throws -> JSONValue {
        guard let value = self[name] else { throw ClientFailure.invalidResponse }
        return value
    }
}

enum V1Time {
    static func parse(_ text: String) throws -> Date {
        guard text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})\\z", options: .regularExpression) != nil else { throw ClientFailure.invalidResponse }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: text) { return date }
        f.formatOptions = [.withInternetDateTime]
        guard let date = f.date(from: text) else { throw ClientFailure.invalidResponse }
        return date
    }
    static func format(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
