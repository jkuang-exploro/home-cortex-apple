import Foundation
@preconcurrency import Vision
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

struct ObservationProcessingResult: Sendable {
    let tracks: [ObservationTrack]
    let crops: [ObservationCrop]
    let rawProposalBoxes: [ObservationBox]
    let totalTracks: Int
    let latencyMS: Double
    let proposalLatencyMS: Double
    let trackingLatencyMS: Double
    let rejectedAssociations: Int
}
/// Serial analysis with one retained frame. Never runs Vision or JPEG encoding on the UI actor.
actor ObservationProcessor {
    private var tracker = ObservationTracker()
    private var selector = ObservationSelector()
    private var sequence = 0
    private var maxCropBytes = 524_288
    private var requests: [String: VNTrackObjectRequest] = [:]
    private var handler = VNSequenceRequestHandler()
    private var world: String?
    func reset(settings: ObservationSettings) {
        tracker.reset(); tracker.maxTracks = settings.maxTracks
        selector = ObservationSelector(perTrack: settings.cropsPerTrack,maxBytes: settings.maxBytes,maxCrops: settings.maxCrops)
        maxCropBytes = settings.maxCropBytes
        requests = [:]; handler = VNSequenceRequestHandler(); sequence = 0; world = nil
    }
    func process(_ frame: ObservationFrame, mode: ObservationMode, manual: [ObservationBox]) throws -> ObservationProcessingResult {
        let started = ContinuousClock.now
        try Task.checkCancellation()
        if world != frame.world { requests = [:]; handler = VNSequenceRequestHandler(); world = frame.world }
        sequence += 1
        var predictions: [String: ObservationBox] = [:]
        var rejectedAssociations = 0
        for (id,request) in requests {
            request.trackingLevel = .fast
            do {
                try handler.perform([request],on: frame.image)
                if let result = request.results?.first as? VNDetectedObjectObservation, result.confidence >= 0.5 {
                    let box = ObservationBox(vision: result.boundingBox)
                    if box.valid,let anchor = tracker.tracks.first(where: { $0.id == id })?.appearance,
                       let current = appearance(frame.image,box: box),anchor.compatible(with: current) { predictions[id] = box }
                    else { rejectedAssociations += 1 }
                }
            } catch { /* Ambiguous/lost trackers do not become authoritative associations. */ }
        }
        let trackingMS = Self.milliseconds(started.duration(to: .now))
        let proposalStarted = ContinuousClock.now
        var proposals: [ObservationProposal]
        if mode == .automatic { proposals = try foreground(frame.image) }
        else {
            // Only explicit manual seeds or successful optical continuations are proposals.
            proposals = manual.map { ObservationProposal(box: $0,objectness: nil,visibility: 1,manualSeed: true) } + predictions.values.map { ObservationProposal(box: $0,objectness: nil,visibility: 1) }
        }
        proposals = proposals.compactMap { proposal in
            guard let signature = appearance(frame.image,box: proposal.box) else { return nil }
            var enriched = proposal; enriched.appearance = signature; return enriched
        }
        let proposalMS = Self.milliseconds(proposalStarted.duration(to: .now))
        let matches = tracker.update(proposals,at: frame.capturedAt,world: frame.world,predictions: predictions)
        for (track,proposal) in matches {
            requests[track.id] = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: proposal.box.visionRect))
            if let crop = try crop(frame,track: track,proposal: proposal) { selector.offer(crop) }
        }
        requests = requests.filter { key,_ in tracker.tracks.contains { $0.id == key } }
        let duration = started.duration(to: .now)
        let ms = Self.milliseconds(duration)
        return ObservationProcessingResult(tracks: matches.map(\.0),crops: selector.crops,rawProposalBoxes: proposals.map(\.box),totalTracks: tracker.totalCreated,latencyMS: ms,proposalLatencyMS: proposalMS,trackingLatencyMS: trackingMS,rejectedAssociations: rejectedAssociations)
    }
    private func appearance(_ image: CGImage,box: ObservationBox) -> ObservationAppearance? {
        guard box.valid,let region = image.cropping(to: box.pixels(width: image.width,height: image.height)) else { return nil }
        return ObservationAppearance(image: region)
    }
    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)*1000 + Double(duration.components.attoseconds)/1e15
    }
    private func foreground(_ image: CGImage) throws -> [ObservationProposal] {
        let request = VNGenerateForegroundInstanceMaskRequest()
        request.revision = VNGenerateForegroundInstanceMaskRequestRevision1
        try VNImageRequestHandler(cgImage: image,orientation: .up).perform([request])
        guard let result = request.results?.first else { return [] }
        // Native instance labels, not semantic categories. Bounding boxes come from the mask plane.
        let mask = result.instanceMask
        guard CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8 else { throw ObservationFailure.invalidResponse }
        CVPixelBufferLockBaseAddress(mask,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask,.readOnly) }
        let w = CVPixelBufferGetWidth(mask), h = CVPixelBufferGetHeight(mask), stride = CVPixelBufferGetBytesPerRow(mask)
        guard let base = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: UInt8.self), w > 0,h > 0,w <= 2048,h <= 2048 else { return [] }
        var boxes: [Int: (Int,Int,Int,Int,Int)] = [:]
        for y in 0..<h { for x in 0..<w {
            let label = Int(base[y*stride+x])
            guard label > 0, result.allInstances.contains(label) else { continue }
            let old = boxes[label] ?? (x,y,x,y,0)
            boxes[label] = (min(x,old.0),min(y,old.1),max(x,old.2),max(y,old.3),old.4+1)
        } }
        return boxes.sorted { $0.key < $1.key }.prefix(16).map { _,b in
            let box = ObservationBox(x: Double(b.0)/Double(w),y: Double(b.1)/Double(h),width: Double(b.2-b.0+1)/Double(w),height: Double(b.3-b.1+1)/Double(h))
            // This API supplies masks, no calibrated per-instance objectness score.
            return ObservationProposal(box: box,objectness: nil,visibility: Double(b.4)/Double((b.2-b.0+1)*(b.3-b.1+1)))
        }
    }
    private func crop(_ frame: ObservationFrame, track: ObservationTrack, proposal: ObservationProposal) throws -> ObservationCrop? {
        let source = frame.image, pixels = proposal.box.pixels(width: source.width,height: source.height)
        // Hard guard: even manual gestures cannot publish an entire frame or almost-full frame.
        guard pixels.width*pixels.height < Double(source.width*source.height)*0.85,
              pixels.width >= 20,pixels.height >= 20,let image = source.cropping(to: pixels) else { return nil }
        let box = ObservationBox(x: pixels.minX/Double(source.width),y: pixels.minY/Double(source.height),width: pixels.width/Double(source.width),height: pixels.height/Double(source.height))
        let (fingerprint,sharpness) = Self.descriptor(image)
        let touchesEdge = pixels.minX == 0 || pixels.minY == 0 || pixels.maxX == Double(source.width) || pixels.maxY == Double(source.height)
        let quality = min(1,sharpness/25) * (touchesEdge ? 0.6 : 1) * (0.5+0.5*proposal.visibility)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data,UTType.jpeg.identifier as CFString,1,nil) else { throw ObservationFailure.storage }
        CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(destination),data.length <= maxCropBytes else { return nil }
        var result = ObservationCrop(id: observationID(),trackID: track.id,jpeg: data as Data,width: image.width,height: image.height,
            sourceWidth: source.width,sourceHeight: source.height,box: box,capturedAt: frame.capturedAt,sequence: sequence,
            quality: quality,fingerprint: fingerprint,diagnostic: frame.diagnostic,objectness: proposal.objectness)
        result.pose = frame.pose; result.cameraID = frame.cameraID
        return result
    }
    private static func descriptor(_ image: CGImage) -> (UInt64,Double) {
        var values = [UInt8](repeating: 0,count: 32*32)
        let ok = values.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress,width: 32,height: 32,bitsPerComponent: 8,bytesPerRow: 32,space: CGColorSpaceCreateDeviceGray(),bitmapInfo: 0) else { return false }
            ctx.interpolationQuality = .medium; ctx.draw(image,in: CGRect(x: 0,y: 0,width: 32,height: 32)); return true
        }
        guard ok else { return (0,0) }
        var hash: UInt64 = 0, edge = 0.0
        for y in 0..<8 { for x in 0..<8 {
            if values[(y*4)*32+x*4] > values[(y*4)*32+min(31,x*4+3)] { hash |= UInt64(1) << (y*8+x) }
        } }
        for y in 1..<31 { for x in 1..<31 {
            let i = y*32+x
            edge += abs(Double(values[i])*4-Double(values[i-1])-Double(values[i+1])-Double(values[i-32])-Double(values[i+32]))
        } }
        return (hash,edge/900)
    }
}
