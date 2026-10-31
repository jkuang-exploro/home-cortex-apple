import SwiftUI

struct ObjectObservationView: View {
    @Bindable var manager: ObservationSessionManager
    let connection: ConnectionController
    let enabled: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var drag: CGRect?
    @State private var reportURL: URL?
    var body: some View {
        DisclosureGroup("Object observation diagnostic") {
            VStack(alignment: .leading,spacing: 12) {
                Toggle("Local experiment (no observation uploads)",isOn: $manager.localOnly).disabled(!manager.canBegin)
                Toggle("Apply app thermal cutoff and slowdown",isOn: $manager.thermalGuardEnabled).disabled(manager.busy)
                Picker("Proposal method",selection: $manager.mode) {
                    ForEach(ObservationMode.allCases,id: \.self) { Text($0.rawValue).tag($0) }
                }.disabled(!manager.canBegin)
                Text(manager.mode == .manual ? "Drag diagonally on the live image to box one object, then release. Wait for the crop count to rise before moving. Repeat for other objects. These are manual proposals." : "Experimental category-agnostic foreground masks. May miss small, occluded or background objects. No identity or category is inferred.").font(.footnote)
                Stepper("Duration: \(Int(manager.settings.duration)) s",value: $manager.settings.duration,in: 30...60,step: 15).disabled(!manager.canBegin)
                LabeledContent("Capture state",value: manager.phase.rawValue).accessibilityIdentifier("observation.state")
                if let message = manager.message {
                    Text(message).font(.footnote).foregroundStyle(manager.phase == .failed ? .red : .secondary).accessibilityIdentifier("observation.message")
                }
                TimelineView(.periodic(from: .now,by: 1)) { _ in LabeledContent("Thermal state",value: manager.thermalStatus) }
                LabeledContent("Elapsed",value: "\(Int(manager.elapsed)) s")
                LabeledContent("Tracks / selected crops",value: "\(manager.trackCount) / \(manager.crops.count)")
                if let frame = manager.frame {
                    GeometryReader { geometry in
                        let size = fit(image: frame.image,in: geometry.size)
                        ZStack(alignment: .topLeading) {
                            Image(decorative: frame.image,scale: 1).resizable().frame(width: size.width,height: size.height)
                            ForEach(manager.regions) { track in
                                Rectangle().stroke(.green,lineWidth: 2).frame(width: track.box.width*size.width,height: track.box.height*size.height)
                                    .offset(x: track.box.x*size.width,y: track.box.y*size.height)
                            }
                            if let drag { Rectangle().stroke(.yellow,lineWidth: 2).frame(width: drag.width,height: drag.height).offset(x: drag.minX,y: drag.minY) }
                        }.frame(width: size.width,height: size.height)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                            guard manager.mode == .manual else { return }
                            manager.holdManualFrame()
                            drag = box(value,in: size)
                        }.onEnded { value in
                            let rect = box(value,in: size)
                            manager.select(ObservationBox(x: rect.minX/size.width,y: rect.minY/size.height,width: rect.width/size.width,height: rect.height/size.height))
                            drag = nil
                        })
                    }.frame(height: 300)
                }
                HStack {
                    Button(manager.localOnly ? "Begin local scan" : "Begin room scan") { manager.begin(connection: connection) }.disabled(!enabled || !manager.canBegin || connection.displayedState != .connected)
                        .accessibilityIdentifier("observation.begin")
                    if manager.phase == .capturing { Button("Finish capture") { manager.finish() } }
                }
                if manager.phase == .uploading { ProgressView(value: Double(manager.acknowledged),total: Double(max(1,manager.crops.count))); Text("Acknowledged \(manager.acknowledged) / \(manager.crops.count)").font(.caption) }
                if manager.hasQueue {
                    HStack {
                        Button("Retry / finish upload") { manager.retry(connection: connection) }.disabled(manager.busy || connection.displayedState != .connected)
                        Button("Cancel scan",role: .destructive) { manager.cancel(connection: connection) }.disabled(!manager.canCancel)
                    }
                    Button("Remove expired local queue") { manager.discardExpired() }.disabled(manager.busy)
                }
                if !manager.crops.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top) {
                            ForEach(manager.crops) { crop in
                                VStack {
                                    if let image = UIImage(data: crop.jpeg) { Image(uiImage: image).resizable().scaledToFit().frame(width: 120,height: 140) }
                                    Text(String(crop.trackID.suffix(8))).font(.caption.monospaced())
                                    Text("\(crop.jpeg.count) bytes · \(crop.pose == nil ? "pose unknown" : "local pose")").font(.caption2)
                                }
                            }
                        }
                    }.accessibilityIdentifier("observation.crops")
                }
                LabeledContent(manager.localOnly ? "Local experiment; server inventory" : "Server inventory",value: "\(manager.inventory.count) observations")
                Text("Only selected object crops are uploaded. Depth and household alignment remain unknown. Foreground only; interruption retains a bounded retry queue.").font(.footnote).foregroundStyle(.secondary)
                Button("Prepare diagnostic report") { reportURL = try? manager.report() }
                if let reportURL { ShareLink("Share diagnostic report",item: reportURL) }
            }.padding(.top,8)
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { manager.interrupt() } }
    }
    private func fit(image: CGImage,in size: CGSize) -> CGSize {
        let scale = min(size.width/Double(image.width),size.height/Double(image.height))
        return CGSize(width: Double(image.width)*scale,height: Double(image.height)*scale)
    }
    private func box(_ drag: DragGesture.Value,in size: CGSize) -> CGRect {
        let x1 = min(size.width,max(0,drag.startLocation.x)), x2 = min(size.width,max(0,drag.location.x))
        let y1 = min(size.height,max(0,drag.startLocation.y)), y2 = min(size.height,max(0,drag.location.y))
        return CGRect(x: min(x1,x2),y: min(y1,y2),width: abs(x2-x1),height: abs(y2-y1))
    }
}
