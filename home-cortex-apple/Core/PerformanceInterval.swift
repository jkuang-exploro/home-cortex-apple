import Foundation
import OSLog

struct PerformanceInterval {
    private static let log = OSLog(subsystem: "HomeCortex", category: .pointsOfInterest)
    private let name: StaticString
    private let id: OSSignpostID
    init(_ name: StaticString) {
        self.name = name
        id = OSSignpostID(log: Self.log)
        os_signpost(.begin, log: Self.log, name: name, signpostID: id)
    }
    func end() { os_signpost(.end, log: Self.log, name: name, signpostID: id) }
}
