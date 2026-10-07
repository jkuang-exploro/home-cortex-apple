import Foundation
import CryptoKit

/// Python sort_keys / compact separators / ensure_ascii=False, for the frozen V1 profile.
enum V1Canonical {
    static func text(_ value: JSONValue) throws -> String {
        switch value {
        case .object(let fields):
            return "{" + (try fields.keys.sorted().map { try text(.string($0)) + ":" + text(fields[$0]!) }).joined(separator: ",") + "}"
        case .array(let values): return "[" + (try values.map(text)).joined(separator: ",") + "]"
        case .string(let string):
            var result = "\""
            for scalar in string.unicodeScalars {
                switch scalar.value {
                case 34: result += "\\\""
                case 92: result += "\\\\"
                case 8: result += "\\b"
                case 12: result += "\\f"
                case 10: result += "\\n"
                case 13: result += "\\r"
                case 9: result += "\\t"
                case 0..<32: result += String(format: "\\u%04x", scalar.value)
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result + "\""
        case .integer(let number): return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .number: throw VisionFailure.invalidArgument
        }
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func evidenceID(_ fields: JSONValue) throws -> String {
        "evidence:" + hash(Data(try text(fields).utf8)).prefix(32)
    }
}

struct CapturedImage: Sendable {
    let jpeg: Data
    let capturedAt: Date
    let cameraID: String
    let width: Int
    let height: Int
    let captureDuration: TimeInterval
    let encodingDuration: TimeInterval
}

enum VisionFailure: Error, Sendable, Equatable {
    case permissionDenied, unavailable, busy, invalidArgument, timeout, internalError, conflict, staleSession
    var code: String {
        switch self {
        case .permissionDenied: "PERMISSION_DENIED"
        case .unavailable: "TEMPORARILY_UNAVAILABLE"
        case .busy: "BUSY"
        case .invalidArgument: "INVALID_ARGUMENT"
        case .timeout: "TIMEOUT"
        case .internalError: "INTERNAL_ERROR"
        case .conflict: "CONFLICT"
        case .staleSession: "CONFLICT"
        }
    }
    var detail: String {
        switch self {
        case .permissionDenied: "camera_permission_denied"
        case .unavailable: "camera_unavailable"
        case .busy: "camera_busy"
        case .invalidArgument: "invalid_arguments"
        case .timeout: "deadline"
        case .internalError: "capture_failure"
        case .conflict: "idempotency_conflict"
        case .staleSession: "stale_session"
        }
    }
    var wire: JSONValue { .object([
        "code": .string(code), "detail_code": .string(detail), "message": .string(message),
        "retryable": .bool(self == .unavailable || self == .busy), "retry_after_ms": .null
    ]) }
    var message: String {
        switch self {
        case .permissionDenied: "Camera access is denied. Enable it in iOS Settings."
        case .unavailable: "The rear camera is temporarily unavailable."
        case .busy: "The camera is busy."
        case .invalidArgument: "The observation arguments or image are invalid."
        case .timeout: "The observation deadline expired."
        case .internalError: "The observation could not be completed."
        case .conflict: "The request ID was reused with different content."
        case .staleSession: "The observation session is no longer active."
        }
    }
}

enum VisualEvidence {
    static let maxMediaBytes = 1_048_576
    static func package(_ image: CapturedImage, body: String, sequence: Int64) throws -> JSONValue {
        guard !image.jpeg.isEmpty, image.jpeg.count <= maxMediaBytes,
              image.jpeg.starts(with: [0xff, 0xd8]), image.jpeg.suffix(2) == Data([0xff, 0xd9]),
              image.width > 0, image.height > 0 else { throw VisionFailure.invalidArgument }
        let timestamp = V1Time.format(image.capturedAt)
        var manifest: [String: JSONValue] = [
            "embodiment_id": .string(body), "camera_id": .string(image.cameraID), "media_type": .string("image"),
            "captured_start": .string(timestamp), "captured_end": .string(timestamp), "duration_ms": .integer(0),
            "sequence_start": .integer(sequence), "sequence_end": .integer(sequence),
            "width": .integer(Int64(image.width)), "height": .integer(Int64(image.height)),
            "content_type": .string("image/jpeg"), "sha256": .string(V1Canonical.hash(image.jpeg)), "reason": .string("manual_observe")
        ]
        manifest["evidence_id"] = .string(try V1Canonical.evidenceID(.object(manifest)))
        return .object(["evidence": .object(manifest), "media_base64": .string(image.jpeg.base64EncodedString())])
    }
}
