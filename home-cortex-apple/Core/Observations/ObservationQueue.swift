import Foundation

struct ObservationUpload: Codable, Sendable {
    var crop: ObservationCrop
    var mediaOperation = observationID()
    var batchOperation = observationID()
    var mediaAcknowledged = false
    var acknowledged = false
}
struct ObservationQueue: Codable, Sendable {
    let body: String
    let client: String
    let origin: String
    let mode: ObservationMode
    let startOperation: String
    var sessionID: String?
    var expiresAt: Date
    var localOnly = false
    var lastError: String?
    var phase = ObservationPhase.idle
    var uploads: [ObservationUpload] = []
    var endOperation: String?
    var endState: String?
    var sessionConfirmed = false
    var inventory: [JSONValue] = []
    var captureStartedAt: Date?
    var metrics = ObservationMetrics()
    var bytes: Int { uploads.reduce(0) { $0+$1.crop.jpeg.count } }
    var pending: Int { uploads.filter { !$0.acknowledged }.count }
    func bound(to access: ObservationAccess) -> Bool { body == access.body && client == access.client && origin == access.origin }
}
struct ObservationMetrics: Codable, Sendable {
    var samples = 0
    var rawProposalCounts: [Int] = []
    var captureTimes: [Date] = []
    var trackSightings: [String: Int] = [:]
    var latencyMS: [Double] = []
    var proposalLatencyMS: [Double] = []
    var trackingLatencyMS: [Double] = []
    var captureSeconds = 0.0
    var createdTracks = 0
    var uploadBytes = 0
    var uploadFailures = 0
    var captureFailures: Int? = 0
    var rejectedAssociations: Int? = 0
    var spatialSamples = 0
    var missingPoseSamples = 0
    var peakMemoryBytes: UInt64 = 0
    var batteryStart: Float?
    var batteryEnd: Float?
    var thermalStates: [String] = []
}
/// One session on disk, ≤8 MiB crops / 16 MiB encoded queue, excluded from backup.
/// No full frames, keys, certificates or auth-session IDs are persisted here.
struct ObservationQueueStore: Sendable {
    let directory: URL
    init(directory: URL? = nil) throws {
        self.directory = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,in: .userDomainMask,appropriateFor: nil,create: true).appendingPathComponent("ObjectObservations",isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory,withIntermediateDirectories: true,attributes: [.protectionKey: FileProtectionType.complete])
        var url = self.directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    var file: URL { directory.appendingPathComponent("queue.json") }
    func load(now: Date = Date()) throws -> ObservationQueue? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16*1024*1024 else { throw ObservationFailure.capacity }
        var queue = try JSONDecoder().decode(ObservationQueue.self,from: Data(contentsOf: file))
        guard queue.bytes <= 8*1024*1024,queue.uploads.count <= 48 else { throw ObservationFailure.capacity }
        if queue.expiresAt <= now { try clear(); return nil }
        for index in queue.uploads.indices where queue.uploads[index].crop.mediaRef == nil { queue.uploads[index].crop.mediaRef = queue.uploads[index].crop.ref }
        return queue
    }
    func save(_ queue: ObservationQueue) throws {
        guard queue.bytes <= 8*1024*1024,queue.uploads.count <= 48 else { throw ObservationFailure.capacity }
        let data = try JSONEncoder().encode(queue)
        guard data.count <= 16*1024*1024 else { throw ObservationFailure.capacity }
        try data.write(to: file,options: [.atomic,.completeFileProtection])
    }
    func clear() throws { if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } }
}
