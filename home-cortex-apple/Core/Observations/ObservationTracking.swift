import Foundation
import CoreGraphics

/// Conservative one-to-one geometric association. Appearance alone never establishes identity.
struct ObservationTracker: Sendable {
    private(set) var tracks: [ObservationTrack] = []
    private(set) var totalCreated = 0
    private var world: String?
    var maxTracks = 12
    mutating func reset() { tracks = []; totalCreated = 0; world = nil }
    mutating func update(_ proposals: [ObservationProposal], at time: Date, world nextWorld: String?, predictions: [String: ObservationBox] = [:]) -> [(ObservationTrack, ObservationProposal)] {
        if nextWorld != world { tracks = []; world = nextWorld }
        tracks.removeAll { time.timeIntervalSince($0.lastSeen) > 4 || time < $0.lastSeen }
        var distinct: [ObservationProposal] = []
        for proposal in proposals where proposal.box.valid && proposal.box.area >= 0.002 && proposal.box.area < 0.85 {
            if !distinct.contains(where: { $0.box.overlap(proposal.box) > 0.9 }) { distinct.append(proposal) }
        }
        let previous = tracks
        var used = Set<String>(), output: [(ObservationTrack,ObservationProposal)] = []
        for proposal in distinct.prefix(maxTracks) {
            let ranked = previous.filter { track in
                !used.contains(track.id) && (track.appearance == nil || proposal.appearance == nil || track.appearance!.compatible(with: proposal.appearance!))
            }.map { track in
                (track.id, (predictions[track.id] ?? track.box).overlap(proposal.box))
            }.sorted { $0.1 > $1.1 }
            let match: String?
            if !proposal.manualSeed,let best = ranked.first, best.1 >= 0.5, ranked.count < 2 || best.1-ranked[1].1 > 0.18 {
                // Reciprocal ambiguity also stays separate (crossing/simultaneous objects).
                let competitors = distinct.filter { (predictions[best.0] ?? previous.first(where: { $0.id == best.0 })!.box).overlap($0.box) >= best.1-0.18 }
                match = competitors.count == 1 ? best.0 : nil
            } else { match = nil }
            if let match, let i = tracks.firstIndex(where: { $0.id == match }) {
                tracks[i].box = proposal.box; tracks[i].lastSeen = time; tracks[i].sightings += 1
                used.insert(match); output.append((tracks[i],proposal))
            } else if tracks.count < maxTracks && totalCreated < maxTracks {
                let track = ObservationTrack(id: "track:"+observationID(),box: proposal.box,lastSeen: time,sightings: 1,appearance: proposal.appearance)
                tracks.append(track); totalCreated += 1; used.insert(track.id); output.append((track,proposal))
            }
        }
        return output
    }
}

struct ObservationSelector: Sendable {
    private(set) var crops: [ObservationCrop] = []
    var perTrack = 3
    var maxBytes = 8*1024*1024
    var maxCrops = 48
    var bytes: Int { crops.reduce(0) { $0+$1.jpeg.count } }
    mutating func offer(_ crop: ObservationCrop) {
        guard crop.quality.isFinite && crop.quality >= 0 else { return }
        let same = crops.indices.filter { crops[$0].trackID == crop.trackID }
        if let duplicate = same.first(where: { (crops[$0].fingerprint ^ crop.fingerprint).nonzeroBitCount <= 5 }) {
            if crop.quality > crops[duplicate].quality * 1.12, bytes-crops[duplicate].jpeg.count+crop.jpeg.count <= maxBytes { crops[duplicate] = crop }
            return
        }
        if same.count < perTrack, crops.count < maxCrops, bytes+crop.jpeg.count <= maxBytes { crops.append(crop); return }
        func utility(_ candidate: ObservationCrop, among peers: [ObservationCrop]) -> Double {
            let differences = peers.compactMap { viewpointDifference(candidate,$0) }
            return candidate.quality + 0.15 * (differences.min() ?? 0)
        }
        if let worst = same.min(by: { i,j in
            utility(crops[i],among: same.filter { $0 != i }.map { crops[$0] }) < utility(crops[j],among: same.filter { $0 != j }.map { crops[$0] })
        }), utility(crop,among: same.filter { $0 != worst }.map { crops[$0] }) > utility(crops[worst],among: same.filter { $0 != worst }.map { crops[$0] }) * 1.15,
           bytes-crops[worst].jpeg.count+crop.jpeg.count <= maxBytes { crops[worst] = crop }
    }
    private func viewpointDifference(_ a: ObservationCrop,_ b: ObservationCrop) -> Double? {
        func rotation(_ crop: ObservationCrop) -> (String,[Double])? {
            guard case .object(let diagnostic) = crop.diagnostic,case .string(let world) = diagnostic["world_id"],
                  case .object(let pose) = diagnostic["camera_pose"],case .array(let values) = pose["quaternion"],values.count == 4 else { return nil }
            let q = values.compactMap { value -> Double? in
                switch value { case .number(let n): n; case .integer(let n): Double(n); default: nil }
            }
            return q.count == 4 ? (world,q) : nil
        }
        guard let (world,q1) = rotation(a),let (other,q2) = rotation(b),world == other else { return nil }
        let dot = zip(q1,q2).reduce(0.0) { $0+$1.0*$1.1 }
        return min(1,2*acos(min(1,abs(dot)))/(Double.pi/4))
    }
}

/// A rejection gate only: similar color distributions never establish object identity.
/// Twenty percent mean RGB histogram-mass change is conservatively treated as uncertain.
struct ObservationAppearance: Sendable {
    let histogram: [Double]
    let fingerprint: UInt64
    let sharpness: Double
    init?(image: CGImage) {
        var pixels = [UInt8](repeating: 0,count: 32*32*4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress,width: 32,height: 32,bitsPerComponent: 8,bytesPerRow: 128,
                space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .medium; context.draw(image,in: CGRect(x: 0,y: 0,width: 32,height: 32)); return true
        }
        guard rendered else { return nil }
        var bins = [Double](repeating: 0,count: 24)
        for index in 0..<1024 { for channel in 0..<3 { bins[channel*8+Int(pixels[index*4+channel])/32] += 1.0/1024 } }
        histogram = bins
        let luminance = (0..<1024).map { index in (77*Double(pixels[index*4])+150*Double(pixels[index*4+1])+29*Double(pixels[index*4+2]))/256 }
        var hash: UInt64 = 0, edge = 0.0
        for y in 0..<8 { for x in 0..<8 {
            if luminance[y*128+x*4] > luminance[y*128+min(31,x*4+3)] { hash |= UInt64(1) << (y*8+x) }
        } }
        for y in 1..<31 { for x in 1..<31 {
            let i = y*32+x
            edge += abs(luminance[i]*4-luminance[i-1]-luminance[i+1]-luminance[i-32]-luminance[i+32])
        } }
        fingerprint = hash; sharpness = edge/900
    }
    func distance(to other: Self) -> Double { zip(histogram,other.histogram).reduce(0) { $0+abs($1.0-$1.1) } / 6 }
    func compatible(with other: Self) -> Bool { distance(to: other) <= 0.2 }
}
