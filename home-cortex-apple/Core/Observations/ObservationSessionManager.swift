import Foundation
import Observation
import UIKit
import Darwin

@MainActor @Observable final class ObservationSessionManager {
    private(set) var phase = ObservationPhase.idle
    private(set) var elapsed = 0.0
    private(set) var regions: [ObservationTrack] = []
    private(set) var crops: [ObservationCrop] = []
    private(set) var frame: ObservationFrame?
    private(set) var trackCount = 0
    private(set) var acknowledged = 0
    private(set) var message: String?
    private(set) var sessionID: String?
    private(set) var metrics = ObservationMetrics()
    private(set) var inventory: [JSONValue] = []
    var thermalGuardEnabled = false
    var localOnly = true
    var mode = ObservationMode.manual
    var settings = ObservationSettings()
    @ObservationIgnored private let camera: any ObservationAcquiring
    @ObservationIgnored private let thermalState: @MainActor () -> Int
    @ObservationIgnored private let processor: ObservationProcessor
    @ObservationIgnored private var storageFailed = false
    @ObservationIgnored private var store: ObservationQueueStore?
    @ObservationIgnored private var queue: ObservationQueue?
    @ObservationIgnored private var worker: Task<Void,Never>?
    @ObservationIgnored private var expiryWorker: Task<Void,Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var seeds: [ObservationBox] = []
    @ObservationIgnored private var access: (@MainActor () throws -> ObservationAccess)?
    @ObservationIgnored private var heldFrame: ObservationFrame?
    @ObservationIgnored private var lastSample: Date?
    var thermalStatus: String {
        let state: String
        switch thermalState() { case 0: state = "Nominal"; case 1: state = "Fair"; case 2: state = "Serious"; default: state = "Critical" }
        return state + (thermalGuardEnabled ? " · app guard on" : " · app guard off")
    }
    var busy: Bool { worker != nil }
    var canBegin: Bool { !busy && queue == nil && !storageFailed }
    var hasQueue: Bool { queue != nil }
    var canCancel: Bool { queue != nil && queue?.endState != "COMPLETED" }

    init(camera: any ObservationAcquiring, store: ObservationQueueStore? = nil, processor: ObservationProcessor = ObservationProcessor(),thermalState: @escaping @MainActor () -> Int = { ProcessInfo.processInfo.thermalState.rawValue }) {
        self.camera = camera; self.processor = processor; self.thermalState = thermalState
        do {
            let disk = try store ?? ObservationQueueStore()
            self.store = disk
            queue = try disk.load()
            armExpiry()
            if let queue,queue.localOnly,queue.captureStartedAt == nil,queue.uploads.isEmpty {
                try disk.clear(); self.queue = nil; localOnly = true; expiryWorker?.cancel(); expiryWorker = nil
                message = "Empty local experiment reset. Choose Manual diagnostic."
            } else if let queue {
                phase = .failed; mode = queue.mode; localOnly = queue.localOnly; sessionID = queue.sessionID; crops = queue.uploads.map(\.crop)
                acknowledged = queue.uploads.filter(\.acknowledged).count; metrics = queue.metrics
                message = "Recovered foreground scan. Retry upload or cancel; capture does not resume automatically."
            }
        } catch { storageFailed = true; phase = .failed; message = "Observation storage is unavailable. \(error.localizedDescription)" }
    }
    func begin(connection: ConnectionController) { begin(access: { try connection.observationAccess() }) }
    func begin(access: @escaping @MainActor () throws -> ObservationAccess) {
        guard canBegin, store != nil else { return }
        do {
            let context = try access()
            self.access = access
            let configuration = settings.bounded; settings = configuration
            var pending = ObservationQueue(body: context.body,client: context.client,origin: context.origin,mode: mode,startOperation: observationID(),expiresAt: Date().addingTimeInterval(900))
            pending.localOnly = localOnly
            pending.metrics.batteryStart = Self.battery()
            pending.metrics.thermalStates = [String(thermalState())]
            try store?.save(pending); queue = pending; armExpiry()
            crops = []; inventory = []; regions = []; seeds = []; frame = nil; heldFrame = nil; lastSample = nil; elapsed = 0; acknowledged = 0; trackCount = 0; metrics = pending.metrics; message = "Starting observation session…"
            generation += 1; let token = generation
            worker = Task { [weak self] in
                guard let self else { return }
                do {
                    if localOnly {
                        queue?.sessionID = observationID(); sessionID = queue?.sessionID; try persist()
                    } else { try await ensureSession(context) }
                    try check(token)
                    guard !thermalGuardEnabled || !ObservationThermalPolicy.stop(thermalState()) else { throw ObservationFailure.thermal }
                    try await camera.beginObservationAcquisition()
                    try check(token)
                    queue?.captureStartedAt = Date(); queue?.phase = .capturing
                    try persist(); phase = .capturing; message = nil
                    await processor.reset(settings: settings)
                    let start = ContinuousClock.now
                    let duration = min(configuration.duration,max(0,(queue?.expiresAt.timeIntervalSinceNow ?? 0)-30))
                    while start.duration(to: .now) < .seconds(duration) {
                        try check(token)
                        let began = ContinuousClock.now
                        try await sample(context: context,token: token)
                        elapsed = Double(start.duration(to: .now).components.seconds)
                        let next = began.advanced(by: .seconds(thermalGuardEnabled ? ObservationThermalPolicy.interval(configuration.sampleInterval,rawState: thermalState()) : configuration.sampleInterval))
                        if next > .now { try await Task.sleep(until: next,clock: .continuous) }
                    }
                    try check(token)
                    metrics.captureSeconds = Date().timeIntervalSince(queue?.captureStartedAt ?? Date())
                    metrics.batteryEnd = Self.battery(); queue?.metrics = metrics
                    camera.endObservationAcquisition()
                    queue?.phase = .uploading; try persist(); phase = .uploading; frame = nil; regions = []
                    if localOnly { try completeLocal(cancelled: false) } else { try await upload(token: token) }
                    if token == generation { worker = nil }
                } catch { fail(error,token: token) }
            }
        } catch { message = error.localizedDescription; phase = .failed }
    }
    func holdManualFrame() { if mode == .manual,heldFrame == nil { heldFrame = frame } }
    func select(_ box: ObservationBox) {
        guard phase == .capturing,mode == .manual else { return }
        guard box.valid,box.area >= 0.002,box.area < 0.85,seeds.count < settings.maxTracks else {
            if seeds.isEmpty { heldFrame = nil }
            message = "Box not accepted. Draw around one object, using more than a tiny tap and less than the whole image."
            return
        }
        // Seeds apply to the currently displayed frame, not an unrelated later camera sample.
        seeds.append(box)
        message = "Manual region queued. The crop count updates on the next sample."
    }
    private func sample(context: ObservationAccess, token: Int) async throws {
        var image: ObservationFrame
        if !seeds.isEmpty,let held = heldFrame ?? frame { image = held; heldFrame = nil }
        else if heldFrame != nil { return }
        else {
            do { image = try await camera.observationFrame(body: context.body) }
            catch let error as VisionFailure where error == .busy || error == .unavailable {
                // Existing camera commands/localization have priority. Bound consecutive missing frames.
                if Date().timeIntervalSince(lastSample ?? queue?.captureStartedAt ?? Date()) > 5 { throw ObservationFailure.interrupted }
                return
            }
        }
        try check(token)
        guard let id = queue?.sessionID,image.capturedAt >= (queue?.captureStartedAt ?? .distantPast).addingTimeInterval(-1),Date().timeIntervalSince(image.capturedAt) < 10 else { seeds = []; heldFrame = nil; return }
        if !localOnly,let diagnostic = image.diagnostic, image.pose == nil,Date().timeIntervalSince(image.capturedAt) < 0.8 {
            do {
                let operation = observationID()
                let result = try await context.transport.send(path: "/sessions/\(id)/capture-poses",method: "POST",payload: .object(["operation_id": .string(operation), "diagnostic": diagnostic]),crop: nil)
                let fields = try result.object(required: ["operation_id","camera_pose"])
                guard fields["operation_id"] == .string(operation) else { throw ObservationFailure.invalidResponse }
                let pose = try fields.field("camera_pose").object(required: ["pose_id","frame","measured_at","pose_frame"])
                guard pose["measured_at"] == .string(V1Time.format(image.capturedAt)),pose["pose_frame"] == .string("camera_optical"),
                      let world = image.world,pose["frame"] == .object(["frame_id": .string(world),"kind": .string("device_local")]),
                      case .string(let poseID) = pose["pose_id"],poseID.range(of: "^pose:[0-9a-f]{64}$",options: .regularExpression) != nil else { throw ObservationFailure.invalidResponse }
                image.pose = fields["camera_pose"]
            } catch is CancellationError { throw CancellationError() }
            catch { /* Unknown reference stays absent. The captured local diagnostic remains in local diagnostics only. */ }
        }
        try check(token)
        let manual = seeds; seeds = []
        let result = try await processor.process(image,mode: mode,manual: manual)
        try check(token)
        if heldFrame == nil { frame = image; regions = result.tracks }; trackCount = result.totalTracks; crops = result.crops; lastSample = Date()
        if metrics.captureTimes.last != image.capturedAt { metrics.samples += 1; metrics.captureTimes.append(image.capturedAt) }
        metrics.latencyMS.append(result.latencyMS)
        metrics.rawProposalCounts.append(result.rawProposalBoxes.count)
        metrics.rejectedAssociations = (metrics.rejectedAssociations ?? 0)+result.rejectedAssociations
        metrics.proposalLatencyMS.append(result.proposalLatencyMS)
        metrics.trackingLatencyMS.append(result.trackingLatencyMS)
        for track in result.tracks { metrics.trackSightings[track.id] = track.sightings }
        if image.pose == nil { metrics.missingPoseSamples += 1 } else { metrics.spatialSamples += 1 }
        metrics.createdTracks = result.totalTracks
        metrics.peakMemoryBytes = max(metrics.peakMemoryBytes,Self.memory())
        let thermal = String(thermalState())
        if !metrics.thermalStates.contains(thermal) { metrics.thermalStates.append(thermal) }
        guard metrics.samples <= 120 else { throw ObservationFailure.capacity }
        queue?.uploads = crops.map { ObservationUpload(crop: $0) }
        queue?.metrics = metrics
        try persist()
        if thermalGuardEnabled && ObservationThermalPolicy.stop(thermalState()) { throw ObservationFailure.thermal }
    }
    func finish() {
        guard phase == .capturing else { return }
        halt()
        metrics.captureSeconds = Date().timeIntervalSince(queue?.captureStartedAt ?? Date()); metrics.batteryEnd = Self.battery()
        queue?.metrics = metrics; queue?.phase = .uploading
        if localOnly { do { try completeLocal(cancelled: false) } catch { message = error.localizedDescription; phase = .failed } } else { startUpload() }
    }
    func retry(connection: ConnectionController) { access = { try connection.observationAccess() }; retry() }
    func retry(access: @escaping @MainActor () throws -> ObservationAccess) { self.access = access; retry() }
    private func retry() { guard !busy,queue != nil else { return }; if localOnly { do { try completeLocal(cancelled: queue?.endState == "CANCELLED") } catch { message = error.localizedDescription } } else { startUpload() } }
    func cancel(connection: ConnectionController? = nil) {
        guard canCancel else { return }
        halt()
        if localOnly { do { try completeLocal(cancelled: true) } catch { message = error.localizedDescription }; return }
        if let connection { access = { try connection.observationAccess() } }
        let operation = queue?.endOperation ?? observationID()
        queue?.endState = "CANCELLED"; queue?.endOperation = operation
        startUpload()
    }
    func interrupt() {
        guard busy || phase == .capturing || phase == .uploading else { return }
        halt(); phase = .failed; queue?.phase = .failed; frame = nil; regions = []; seeds = []
        metrics.captureSeconds = Date().timeIntervalSince(queue?.captureStartedAt ?? Date()); metrics.batteryEnd = Self.battery(); queue?.metrics = metrics
        queue?.lastError = ObservationFailure.interrupted.localizedDescription
        do { try persist(); message = ObservationFailure.interrupted.localizedDescription }
        catch { message = error.localizedDescription }
    }
    /// Only expired local queues can be discarded without resolving the remote terminal operation.
    func reapExpired() {
        guard let queue,queue.expiresAt <= Date() else { return }
        halt(); discardExpired()
    }
    private func armExpiry() {
        expiryWorker?.cancel()
        guard let deadline = queue?.expiresAt else { return }
        expiryWorker = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0,deadline.timeIntervalSinceNow))) } catch { return }
            self?.reapExpired()
        }
    }
    func discardExpired() {
        guard !busy,let queue,queue.expiresAt <= Date() else { return }
        do { try store?.clear(); self.queue = nil; crops = []; phase = .idle; message = "Expired local evidence removed." }
        catch { message = error.localizedDescription }
    }
    private func completeLocal(cancelled: Bool) throws {
        camera.endObservationAcquisition()
        guard queue?.localOnly == true else { throw ObservationFailure.invalidResponse }
        phase = cancelled ? .cancelled : .completed
        message = cancelled ? "Local diagnostic cancelled. No server session was created." : "Local diagnostic completed. No server session or uploads; these are diagnostic crops only."
        try store?.clear(); queue = nil; frame = nil; regions = []; expiryWorker?.cancel(); expiryWorker = nil
    }
    private func halt() { camera.endObservationAcquisition(); generation += 1; worker?.cancel(); worker = nil; regions = []; frame = nil; seeds = []; heldFrame = nil }
    private func startUpload() {
        guard queue != nil,let access,!busy else { return }
        generation += 1; let token = generation
        phase = .uploading; message = nil
        worker = Task { [weak self] in
            guard let self else { return }
            do {
                let context = try access()
                guard queue?.bound(to: context) == true else { throw ClientFailure.authenticationRequired }
                try await ensureSession(context); try check(token)
                try await upload(token: token)
                if token == generation { worker = nil }
            } catch { fail(error,token: token) }
        }
    }
    private func ensureSession(_ context: ObservationAccess) async throws {
        guard let queue,queue.bound(to: context),Date() < queue.expiresAt else { throw ObservationFailure.expired }
        guard queue.sessionID == nil else { return }
        let result = try await send(path: "/sessions",method: "POST",payload: .object(["operation_id": .string(queue.startOperation),"capture_policy_version": .string("object-crops.v1")]),crop: nil)
        let fields = try result.object(required: ["operation_id","session"])
        guard fields["operation_id"] == .string(queue.startOperation),case .object(let session) = fields["session"],case .string(let id) = session["session_id"],UUID(uuidString: id)?.version4 == true,
              session["state"] == .string("OPEN"),session["embodiment_id"] == .string(context.body),case .string(let expiry) = session["expires_at"] else { throw ObservationFailure.invalidResponse }
        if case .object(let limits) = session["limits"] {
            func limit(_ key: String) throws -> Int {
                guard case .integer(let n) = limits[key],n > 0,n <= 67_108_864 else { throw ObservationFailure.invalidResponse }
                return Int(n)
            }
            settings.maxBytes = min(settings.maxBytes,try limit("max_session_media_bytes"))
            settings.maxCrops = min(48,try limit("max_session_observations"))
            settings.maxCropBytes = min(524_288,try limit("max_crop_bytes"))
        }
        try Task.checkCancellation()
        self.queue?.sessionID = id; sessionID = id
        self.queue?.expiresAt = min(queue.expiresAt,try V1Time.parse(expiry))
        armExpiry()
        try persist()
    }
    private func upload(token: Int) async throws {
        guard let access,let initial = queue,let id = initial.sessionID else { throw ObservationFailure.invalidResponse }
        guard Date() < initial.expiresAt else { throw ObservationFailure.expired }
        if initial.endState != "CANCELLED" {
            for index in initial.uploads.indices {
                try check(token)
                guard var item = queue?.uploads[index],!item.acknowledged else { continue }
                let context = try access()
                guard queue?.bound(to: context) == true else { throw ClientFailure.authenticationRequired }
                if !item.mediaAcknowledged {
                    let payload = JSONValue.object(["operation_id": .string(item.mediaOperation),"session_id": .string(id),"crop": item.crop.reference])
                    let reply = try await send(path: "/sessions/\(id)/media",method: "POST",payload: payload,crop: item.crop.jpeg)
                    try check(token)
                    guard case .object(let r) = reply,r["operation_id"] == .string(item.mediaOperation),r["crop"] == item.crop.reference,
                          r["disposition"] == .string("accepted") || r["disposition"] == .string("duplicate") else { throw ObservationFailure.invalidResponse }
                    item.mediaAcknowledged = true; queue?.uploads[index] = item
                    metrics.uploadBytes += item.crop.jpeg.count+(try JSONEncoder().encode(payload).count)
                    queue?.metrics = metrics; try persist()
                }
                let payload = JSONValue.object(["operation_id": .string(item.batchOperation),"session_id": .string(id),"observations": .array([item.crop.wire(session: id,mode: initial.mode)])])
                let reply = try await send(path: "/sessions/\(id)/batches",method: "POST",payload: payload,crop: nil)
                try check(token)
                guard case .object(let r) = reply,r["operation_id"] == .string(item.batchOperation),case .array(let receipts) = r["receipts"],receipts.count == 1,case .object(let receipt) = receipts[0],receipt["observation_id"] == .string(item.crop.id) else { throw ObservationFailure.invalidResponse }
                guard receipt["disposition"] == .string("accepted") || receipt["disposition"] == .string("duplicate") else {
                    if case .object(let error) = receipt["error"],case .string(let detail) = error["detail_code"] {
                        if error["retryable"] == .bool(true) {
                            // A recorded rejection is immutable; a later attempt needs a fresh batch operation.
                            item.batchOperation = observationID()
                            if detail == "crop_missing" { item.mediaAcknowledged = false; item.mediaOperation = observationID() }
                            queue?.uploads[index] = item; try persist()
                        }
                        throw ObservationFailure.server(422,detail,error["retryable"] == .bool(true),2000)
                    }
                    throw ObservationFailure.invalidResponse
                }
                item.acknowledged = true; queue?.uploads[index] = item
                acknowledged = queue?.uploads.filter(\.acknowledged).count ?? 0
                metrics.uploadBytes += try JSONEncoder().encode(payload).count; queue?.metrics = metrics; try persist()
            }
        }
        try check(token)
        if queue?.endOperation == nil { queue?.endOperation = observationID(); queue?.endState = "COMPLETED"; try persist() }
        guard let operation = queue?.endOperation,let target = queue?.endState else { throw ObservationFailure.invalidResponse }
        let context = try access()
        guard queue?.bound(to: context) == true else { throw ClientFailure.authenticationRequired }
        let reply = try await send(path: "/sessions/\(id)/end",method: "POST",payload: .object(["operation_id": .string(operation),"state": .string(target)]),crop: nil)
        try check(token)
        guard case .object(let r) = reply,r["operation_id"] == .string(operation),case .object(let session) = r["session"],session["session_id"] == .string(id),session["state"] == .string(target) else { throw ObservationFailure.invalidResponse }
        queue?.sessionConfirmed = true; try persist()
        if target == "COMPLETED" { try await verifyInventory(context: context,id: id,token: token) }
        try check(token)
        phase = target == "CANCELLED" ? .cancelled : .completed
        message = target == "CANCELLED" ? "Server cancellation confirmed." : "Server completion and inventory confirmed."
        try store?.clear(); queue = nil; expiryWorker?.cancel(); expiryWorker = nil
    }
    private func verifyInventory(context: ObservationAccess,id: String,token: Int) async throws {
        var cursor: String?, entries: [JSONValue] = [], seen = Set<String>(), cursors = Set<String>()
        repeat {
            let query = cursor.map { "&cursor="+($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "") } ?? ""
            let result = try await send(path: "/sessions/\(id)/inventory?limit=16"+query,method: "GET",payload: nil,crop: nil)
            try check(token)
            guard case .object(let r) = result,r["session_id"] == .string(id),case .array(let rows) = r["entries"],rows.count <= 16 else { throw ObservationFailure.invalidResponse }
            for row in rows {
                guard case .object(let fields) = row,case .object(let observation) = fields["observation"],case .string(let observationID) = observation["observation_id"],seen.insert(observationID).inserted,
                      let expected = queue?.uploads.first(where: { $0.crop.id == observationID }),case .object(let wire) = expected.crop.wire(session: id,mode: mode),
                      observation["session_id"] == .string(id),observation["track_id"] == .string(expected.crop.trackID),observation["crop"] == expected.crop.reference,
                      observation["provenance"] == wire["provenance"],observation["captured_at"] == wire["captured_at"],observation["region"]?.withoutNulls == wire["region"]?.withoutNulls,
                      (observation["camera_pose"] ?? .null).withoutNulls == (wire["camera_pose"] ?? .null).withoutNulls else { throw ObservationFailure.invalidResponse }
                entries.append(row)
            }
            if case .string(let next) = r["next_cursor"] { guard next.count <= 256,cursors.insert(next).inserted else { throw ObservationFailure.invalidResponse }; cursor = next }
            else if r["next_cursor"] == .null { cursor = nil } else { throw ObservationFailure.invalidResponse }
            guard entries.count <= 48 else { throw ObservationFailure.capacity }
        } while cursor != nil
        guard seen == Set(queue?.uploads.map { $0.crop.id } ?? []) else { throw ObservationFailure.invalidResponse }
        inventory = entries
    }
    private func send(path: String,method: String,payload: JSONValue?,crop: Data?) async throws -> JSONValue {
        guard let access,queue?.localOnly == false else { throw ClientFailure.authenticationRequired }
        for attempt in 0..<4 {
            try Task.checkCancellation()
            guard let queue,Date() < queue.expiresAt else { throw ObservationFailure.expired }
            do {
                let current = try access()
                guard queue.bound(to: current) else { throw ClientFailure.authenticationRequired }
                return try await current.transport.send(path: path,method: method,payload: payload,crop: crop)
            } catch {
                if error is CancellationError { throw error }
                let retry: Bool
                var delay = min(8,1 << attempt)*1000
                if case ObservationFailure.server(_,_,let allowed,let suggested) = error { retry = allowed; delay = max(delay,suggested) }
                else { retry = error is URLError || error as? ClientFailure == .authenticationRequired || error as? ClientFailure == .transport }
                guard retry,attempt < 3 else { throw error }
                metrics.uploadFailures += 1
                message = "Connection interrupted. Retrying the same operation…"
                try await Task.sleep(for: .milliseconds(delay))
            }
        }
        throw ObservationFailure.invalidResponse
    }
    private func persist() throws { if let queue { guard let store else { throw ObservationFailure.storage }; try store.save(queue) } }
    private func check(_ token: Int) throws { try Task.checkCancellation(); guard token == generation else { throw CancellationError() } }
    private func fail(_ error: any Error,token: Int) {
        guard token == generation else { return }
        camera.endObservationAcquisition()
        let uploading = phase == .uploading
        worker = nil; phase = .failed; frame = nil; regions = []
        if uploading { metrics.uploadFailures += 1 } else { metrics.captureFailures = (metrics.captureFailures ?? 0)+1 }
        queue?.metrics = metrics; queue?.phase = .failed
        message = error.localizedDescription
        queue?.lastError = String(error.localizedDescription.prefix(400))
        do { try persist() } catch { message = error.localizedDescription }
    }
    func report() throws -> URL {
        let report = ObservationDiagnosticReport(mode: mode.rawValue,localOnly: localOnly,thermalGuardEnabled: thermalGuardEnabled,error: message,sessionID: sessionID,state: phase.rawValue,metrics: metrics,crops: crops.map { .init(id: $0.id,track: $0.trackID,bytes: $0.jpeg.count,jpeg: $0.jpeg,pose: $0.pose,localDiagnostic: $0.diagnostic) },inventory: inventory)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("observation-diagnostics.json")
        try JSONEncoder().encode(report).write(to: url,options: [.atomic,.completeFileProtection]); return url
    }
    private static func battery() -> Float? { UIDevice.current.isBatteryMonitoringEnabled = true; let value = UIDevice.current.batteryLevel; return value >= 0 ? value : nil }
    private static func memory() -> UInt64 {
        var info = task_vm_info_data_t(); var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self,capacity: Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) } }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
private struct ObservationDiagnosticReport: Codable {
    struct Crop: Codable { let id: String; let track: String; let bytes: Int; let jpeg: Data; let pose: JSONValue?; let localDiagnostic: JSONValue? }
    let mode: String; let localOnly: Bool; let thermalGuardEnabled: Bool; let error: String?; let sessionID: String?; let state: String; let metrics: ObservationMetrics; let crops: [Crop]; let inventory: [JSONValue]
}
private extension UUID { var version4: Bool { uuid.6 >> 4 == 4 } }
private extension JSONValue {
    var withoutNulls: JSONValue {
        switch self {
        case .object(let fields): .object(fields.filter { $0.value != .null }.mapValues(\.withoutNulls))
        case .array(let values): .array(values.map(\.withoutNulls))
        case .number(let n) where n.isFinite && n.rounded() == n && abs(n) < 9_007_199_254_740_991: .integer(Int64(n))
        default: self
        }
    }
}
