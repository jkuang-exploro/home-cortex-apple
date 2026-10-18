import Foundation
import simd

struct VisualFrame: Sendable {
    let pixels: Data
    let width: Int, height: Int, stride: Int
    let intrinsics: VisualIntrinsics
    let worldFromARCamera: RigidTransform
    let worldID: String
    let measuredAt: Date
}

/// C detector and nonlinear solve stay off the main actor; raw pixels are copied
/// once and bounded to a single in-flight frame by the detector worker.
private final class AprilTagHandle: @unchecked Sendable {
    let pointer = hc_detector_create()
    deinit { hc_detector_destroy(pointer) }
}
actor VisualAnchorDetector {
    // The handle's lifetime is Sendable; its mutable C state is actor-confined.
    private let detector = AprilTagHandle()
    private var cachedTags: [VisualTag] = []
    private var catalog: VisualPoseSolver.PreparedCatalog?
    private var sizes = [Double](repeating: 0, count: 587)
    private var output = [HCDetection](repeating: HCDetection(), count: 128)
    private func prepare(tags: [VisualTag]) throws {
        guard catalog == nil || cachedTags != tags else { return }
        guard tags.allSatisfy({ (0..<sizes.count).contains($0.id) && $0.edge.isFinite && $0.edge > 0 }) else { throw VisualAnchorError.catalog }
        let next = try VisualPoseSolver.PreparedCatalog(tags: tags)
        sizes = [Double](repeating: 0, count: 587)
        for tag in tags { sizes[tag.id] = tag.edge }
        cachedTags = tags; catalog = next
    }
    func detections(frame: VisualFrame, tags: [VisualTag]) throws -> [VisualDetection] {
        try Task.checkCancellation()
        try prepare(tags: tags)
        guard frame.width > 0, frame.width <= 8192, frame.height > 0, frame.height <= 8192,
              frame.stride >= frame.width, frame.stride <= 65_536,
              frame.pixels.count >= frame.stride * frame.height else { throw VisualAnchorError.catalog }
        let interval = PerformanceInterval("AprilTagDetect")
        defer { interval.end() }
        let k = frame.intrinsics
        let count = frame.pixels.withUnsafeBytes { bytes in
            sizes.withUnsafeBufferPointer { sizes in
                output.withUnsafeMutableBufferPointer { output in
                    hc_detect(detector.pointer, bytes.bindMemory(to: UInt8.self).baseAddress,
                        Int32(frame.width), Int32(frame.height), Int32(frame.stride),
                        k.fx, k.fy, k.cx, k.cy, sizes.baseAddress, sizes.count, output.baseAddress, Int32(output.count))
                }
            }
        }
        return try output.prefix(Int(count)).map { raw -> VisualDetection in
            let corners = withUnsafeBytes(of: raw.corners) { bytes in
                let values = bytes.bindMemory(to: Double.self)
                return (0..<4).map { SIMD2(values[2*$0], values[2*$0+1]) }
            }
            func transform<T>(_ value: T) throws -> RigidTransform {
                try withUnsafeBytes(of: value) { try RigidTransform(rowMajor: $0.bindMemory(to: Double.self)) }
            }
            return VisualDetection(id: Int(raw.tag_id), corners: corners,
                cameraFromTag: try transform(raw.camera_from_tag),
                alternative: raw.has_alternative == 1 ? try transform(raw.alternative_camera_from_tag) : nil)
        }
    }
    func solve(frame: VisualFrame, tags: [VisualTag]) throws -> VisualSolution {
        let detections = try detections(frame: frame, tags: tags)
        try Task.checkCancellation()
        guard let catalog else { throw VisualAnchorError.catalog }
        return try VisualPoseSolver.solve(catalog: catalog, detections: detections, intrinsics: frame.intrinsics)
    }
}
