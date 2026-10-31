import Foundation
import CoreGraphics
import CryptoKit

/// All image coordinates are normalized, top-left origin in the upright sampled image.
struct ObservationBox: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var area: Double { width * height }
    var valid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1.000001 && y + height <= 1.000001 }
    var visionRect: CGRect { CGRect(x: x, y: 1-y-height, width: width, height: height) }
    init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    init(vision: CGRect) { x = vision.minX; y = 1-vision.maxY; width = vision.width; height = vision.height }
    func overlap(_ other: Self) -> Double {
        let intersection = max(0, min(x+width,other.x+other.width)-max(x,other.x)) * max(0,min(y+height,other.y+other.height)-max(y,other.y))
        return intersection / max(0.000001, area+other.area-intersection)
    }
    func pixels(width w: Int, height h: Int, margin: Double = 0.04) -> CGRect {
        let left = max(0, floor((x-width*margin)*Double(w))), top = max(0,floor((y-height*margin)*Double(h)))
        let right = min(Double(w),ceil((x+width*(1+margin))*Double(w))), bottom = min(Double(h),ceil((y+height*(1+margin))*Double(h)))
        return CGRect(x: left,y: top,width: right-left,height: bottom-top)
    }
    var wire: JSONValue { .object(["x_min": .number(x), "y_min": .number(y), "x_max": .number(x+width), "y_max": .number(y+height)]) }
}

enum ObservationMode: String, Codable, CaseIterable { case manual = "Manual diagnostic", automatic = "Automatic foreground (experimental)"
    var profile: String { self == .manual ? "vision_producer:ios_manual_v1" : "vision_producer:ios_foreground_v1" }
}
enum ObservationPhase: String, Codable { case idle = "IDLE", capturing = "CAPTURING", uploading = "UPLOADING", completed = "COMPLETED", cancelled = "CANCELLED", failed = "FAILED" }
struct ObservationSettings: Sendable {
    var duration: Double = 60
    var sampleInterval: Double = 1.5
    var maxTracks = 12
    var cropsPerTrack = 3
    var maxBytes = 8 * 1024 * 1024
    var maxCropBytes = 524_288
    var maxCrops = 48
    var bounded: Self { var v = self; v.duration = min(60,max(30,duration)); v.sampleInterval = min(5,max(1,sampleInterval)); v.maxTracks = min(16,max(1,maxTracks)); v.cropsPerTrack = min(3,max(1,cropsPerTrack)); v.maxBytes = min(8*1024*1024,max(1024,maxBytes)); return v }
}
struct ObservationFrame: @unchecked Sendable {
    // CGImage is immutable; no camera buffers escape their existing owner.
    let image: CGImage
    let capturedAt: Date
    let diagnostic: JSONValue?
    var pose: JSONValue? = nil
    var cameraID = "camera:rear-primary"
    var world: String? { guard case .object(let d) = diagnostic, case .string(let s) = d["world_id"] else { return nil }; return s }
}
@MainActor protocol ObservationAcquiring: AnyObject {
    func beginObservationAcquisition() async throws
    func endObservationAcquisition()
    func observationFrame(body: String) async throws -> ObservationFrame
}
extension ObservationAcquiring {
    func beginObservationAcquisition() async throws { }
    func endObservationAcquisition() { }
}

struct ObservationProposal: Sendable {
    let box: ObservationBox
    let objectness: Double?
    let visibility: Double
    var appearance: ObservationAppearance? = nil
    var manualSeed = false
}
struct ObservationTrack: Sendable, Identifiable {
    let id: String
    var box: ObservationBox
    var lastSeen: Date
    var sightings: Int
    var appearance: ObservationAppearance? = nil
}
struct ObservationCrop: Codable, Sendable, Identifiable {
    let id: String
    let trackID: String
    let jpeg: Data
    let width: Int
    let height: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let box: ObservationBox
    let capturedAt: Date
    let sequence: Int
    let quality: Double
    let fingerprint: UInt64
    let diagnostic: JSONValue?
    let objectness: Double?
    var pose: JSONValue? = nil
    var cameraID = "camera:rear-primary"
    var ref: String { "sha256:" + SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined() }
    var reference: JSONValue { .object(["ref": .string(ref), "kind": .string("crop"), "media_type": .string("image/jpeg"), "byte_length": .integer(Int64(jpeg.count)), "width": .integer(Int64(width)), "height": .integer(Int64(height))]) }
    func wire(session: String, mode: ObservationMode) -> JSONValue {
        var fields: [String: JSONValue] = ["observation_id": .string(id), "session_id": .string(session), "track_id": .string(trackID),
            "captured_at": .string(V1Time.format(capturedAt)), "crop": reference,
            "region": .object(["source_width": .integer(Int64(sourceWidth)), "source_height": .integer(Int64(sourceHeight)), "bbox": box.wire]),
            "coordinate_frame": .object(["frame_id": .string("image:"+cameraID.replacingOccurrences(of: "camera:",with: "")), "kind": .string("image")]),
            "provenance": .object(["camera_id": .string(cameraID), "producer_profile_id": .string(mode.profile), "capture_sequence": .integer(Int64(sequence))])]
        if let objectness { fields["detection_score"] = .object(["value": .number(objectness), "semantics": .string("producer_objectness")]) }
        if let pose { fields["camera_pose"] = pose }
        return .object(fields)
    }
}
func observationID() -> String { UUID().uuidString.lowercased() }

enum ObservationFailure: Error, LocalizedError {
    case invalidResponse, storage, capacity, interrupted, thermal, server(Int, String, Bool, Int), expired
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid observation response."
        case .storage: "Observation queue could not be saved."
        case .capacity: "The bounded observation queue is full."
        case .interrupted: "Capture interrupted; finish or cancel the saved evidence."
        case .thermal: "Capture stopped at serious thermal state. Let the phone cool, then finish or cancel the saved evidence."
        case .expired: "The observation session expired. Discard the local queue."
        case .server(let status,let detail,_,_): "Observation server \(status): \(detail)"
        }
    }
}

/// Conservative foreground budget; temperature is a system signal, not an attribution to Vision.
enum ObservationThermalPolicy {
    static func stop(_ rawState: Int) -> Bool { rawState >= 2 }
    static func interval(_ configured: Double, rawState: Int) -> Double { rawState >= 1 ? max(3,configured) : configured }
}
