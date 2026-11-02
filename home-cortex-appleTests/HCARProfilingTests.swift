import XCTest
import CoreGraphics
@testable import HomeCortex

final class HCARProfilingTests: XCTestCase {
    @MainActor func testSyntheticProcessingPersistenceAndReceiptFootprint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(observationID())
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ObservationQueueStore(directory: root.appendingPathComponent("crops"))
        let processor = ObservationProcessor(), box = ObservationBox(x: 0.1,y: 0.1,width: 0.3,height: 0.3)
        let context = CGContext(data: nil,width: 1600,height: 1200,bitsPerComponent: 8,bytesPerRow: 6400,space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for x in stride(from: 0,to: 1600,by: 8) { context.setFillColor(CGColor(gray: Double(x%256)/255,alpha: 1)); context.fill(CGRect(x: x,y: 0,width: 8,height: 1200)) }
        let frame = ObservationFrame(image: context.makeImage()!,capturedAt: Date(),diagnostic: nil)
        var processing: [Double] = [], persistence: [Double] = []
        for _ in 0..<12 {
            await processor.reset(settings: ObservationSettings())
            processing.append(try await processor.process(frame,mode: .manual,manual: [box]).latencyMS)
        }
        var jpeg = Data(repeating: 0x17,count: 524288); jpeg[0] = 0xff; jpeg[1] = 0xd8; jpeg[jpeg.count-2] = 0xff; jpeg[jpeg.count-1] = 0xd9
        let crop = ObservationCrop(id: observationID(),trackID: "track:profile",jpeg: jpeg,width: 480,height: 360,sourceWidth: 1600,sourceHeight: 1200,box: box,capturedAt: frame.capturedAt,sequence: 1,quality: 1,fingerprint: 0,diagnostic: nil,objectness: nil)
        var queue = ObservationQueue(body: "embodiment:test",client: "client:test",origin: "https://example.test",mode: .manual,startOperation: observationID(),expiresAt: Date().addingTimeInterval(60))
        queue.uploads = (0..<16).map { _ in ObservationUpload(crop: crop) }
        var longestGap = 0.0, lastTick = Date()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                longestGap = max(longestGap,Date().timeIntervalSince(lastTick)*1000); lastTick = Date()
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        await Task.yield()
        for _ in 0..<12 {
            let start = Date()
            #if HC_AR_BASELINE
            try store.save(queue)
            #else
            try await processor.persist(queue,store: store)
            #endif
            persistence.append(Date().timeIntervalSince(start)*1000)
        }
        try await Task.sleep(for: .milliseconds(5)); ticker.cancel()
        let id = observationID(), now = Date()
        let raw = JSONValue.object(["protocol_version": .string("1.0"),"schema_name": .string("hc.request"),"schema_version": .integer(1),"message_id": .string(id),"request_id": .string(id),"sent_at": .string(V1Time.format(now.addingTimeInterval(-1))),"deadline_at": .string(V1Time.format(now.addingTimeInterval(10))),"target": .object(["embodiment_id": .string("embodiment:test"),"session_id": .string("session:test")]),"operation": .string("vision.observe"),"arguments": .object([:])])
        let command = try VisionCommand(raw,body: "embodiment:test",session: "session:test")
        let receipts = try VisionReceipts(identity: "profile",root: root)
        _ = try await receipts.begin(command)
        let image = CapturedImage(jpeg: jpeg,capturedAt: now,cameraID: "camera:test",width: 480,height: 360,captureDuration: 0,encodingDuration: 0)
        let response = command.reply(result: try VisualEvidence.package(image,body: "embodiment:test",sequence: 1))
        let start = Date(); try await receipts.finish(command,response: response)
        let receiptMS = Date().timeIntervalSince(start)*1000
        let directory = root.appendingPathComponent("V1Vision/"+V1Canonical.hash(Data("profile".utf8)))
        func bytes(_ extensionName: String) throws -> Int {
            try FileManager.default.contentsOfDirectory(at: directory,includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == extensionName }.reduce(0) { try $0+($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        }
        let pendingMetadata = try bytes("json"), pendingJPEG = try bytes("jpg")
        #if !HC_AR_BASELINE
        try await receipts.acknowledge(response)
        #endif
        let metrics: [String: Double] = ["processing_median_ms": processing.sorted()[6],"persist_8MiB_median_ms": persistence.sorted()[6],"main_actor_longest_gap_ms": longestGap,"queue_bytes": Double(try Data(contentsOf: store.file).count),"receipt_finish_ms": receiptMS,"pending_receipt_json_bytes": Double(pendingMetadata),"pending_jpeg_bytes": Double(pendingJPEG),"final_receipt_json_bytes": Double(try bytes("json")),"final_jpeg_bytes": Double(try bytes("jpg"))]
        print("HC_AR_PROFILE "+String(decoding: try JSONEncoder().encode(metrics),as: UTF8.self))
        XCTAssertEqual(queue.bytes,8*1024*1024)
        #if !HC_AR_BASELINE
        XCTAssertLessThan(longestGap,250,"Large evidence persistence stalled UI scheduling")
        #endif
    }
}
