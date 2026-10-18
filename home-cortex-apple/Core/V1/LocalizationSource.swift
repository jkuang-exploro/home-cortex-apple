import Foundation

@MainActor protocol LocalizationTracking: AnyObject {
    var worldID: String? { get }
    var measuredAt: Date? { get }
    var cameraPose: RigidTransform? { get }
    var state: LocalizationState { get }
    @discardableResult func poll() -> Bool
    func visualFrame() throws -> VisualFrame
    func diagnostic(body: String) -> JSONValue?
}

@MainActor protocol LocalizationCamera: AnyObject {
    var localTracking: any LocalizationTracking { get }
    func useTracking(_ enabled: Bool) async
    func stopTracking()
}

extension ARLocalTracking: LocalizationTracking {}
extension NativeStillImageCapture: LocalizationCamera {
    var localTracking: any LocalizationTracking { tracking }
}

protocol VisualAnchorSolving: Sendable {
    func solve(frame: VisualFrame, tags: [VisualTag]) async throws -> VisualSolution
}
extension VisualAnchorDetector: VisualAnchorSolving {}

struct LocalizationAccess: Sendable {
    let body: String
    let session: String
    let transport: any InspectionTransport
}
