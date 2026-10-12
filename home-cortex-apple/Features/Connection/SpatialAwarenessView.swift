import SwiftUI
import simd

struct SpatialAwarenessView: View {
    @Bindable var embodiment: EmbodimentController
    let caller: ConnectionController
    @State private var wizard = false
    private var calibration: VisualAnchorCalibration { embodiment.localization.visualCalibration }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Spatial Awareness").font(.headline)
            LabeledContent("Motion tracking", value: embodiment.localization.camera.tracking.supported ? "Supported" : "Unavailable")
            LabeledContent("Room alignment", value: calibration.aligned ? "Aligned from vision" : "Needs anchor calibration")
            LabeledContent("Space", value: embodiment.selectedLocalizationSpace?.displayName ?? "Not selected")
            Text(calibration.message).font(.footnote)
            AnchorCalibrationFeedback(calibration: calibration, isActive: !wizard)
            if let pose = calibration.cameraPose {
                VisualPoseReadout(pose: pose)
                Text("Rear camera optical center · Room coordinates · Accuracy unvalidated").font(.footnote)
            }
            if let time = calibration.calibratedAt {
                LabeledContent("Last anchor observation", value: time.formatted(date: .abbreviated, time: .shortened))
            }
            Button(calibration.aligned ? "Recalibrate from anchors" : "Calibrate facing an anchor") { wizard = true }
                .accessibilityIdentifier("embodiment.spatial.setup")
                .disabled(caller.displayedState != .connected)
            if !embodiment.localizationSelected {
                Text("Turn on Visual-inertial localization in Embodiment before capturing.").font(.footnote)
            }
        }
        .sheet(isPresented: $wizard) { VisualAnchorCalibrationView(embodiment: embodiment, caller: caller) }
    }
}

private struct VisualPoseReadout: View {
    let pose: RigidTransform
    var body: some View {
        let angles = IPhoneBodyFrame.euler(pose.rotation)
        LabeledContent("Camera X / Y / Z", value: String(format: "%.3f / %.3f / %.3f m", pose.translation.x, pose.translation.y, pose.translation.z))
        LabeledContent("Camera yaw / pitch / roll", value: String(format: "%.1f / %.1f / %.1f°", angles.x*180 / .pi, angles.y*180 / .pi, angles.z*180 / .pi))
    }
}

/// Used both in the scanner and after it closes: background observations still
/// deliver completion feedback and a conflict can never become a hidden warning.
private struct AnchorCalibrationFeedback: View {
    let calibration: VisualAnchorCalibration
    var isActive = true
    @State private var notice: String?
    @State private var showingConflict = false
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.headline)
                    .accessibilityIdentifier("spatial.calibration.finished")
            }
            ForEach(calibration.completedBoardIDs, id: \.self) { id in
                Label(id + ": Calibration finished", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if !calibration.ignoredBoardIDs.isEmpty {
                Text("Skipped until recalibration: " + calibration.ignoredBoardIDs.joined(separator: ", "))
                    .font(.footnote)
            }
            if let failure { Text(failure).foregroundStyle(.red) }
        }
        .sensoryFeedback(.success, trigger: calibration.completionSequence) { _, _ in
            isActive && calibration.completionNotice != nil
        }
        .task(id: calibration.completionSequence) {
            guard isActive, let message = calibration.completionNotice else { return }
            notice = message
            UIAccessibility.post(notification: .announcement, argument: message)
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            notice = nil
        }
        .onChange(of: calibration.completedBoardIDs) {
            if calibration.completedBoardIDs.isEmpty { notice = nil }
        }
        .onChange(of: calibration.pendingConflict?.id, initial: true) {
            showingConflict = isActive && calibration.pendingConflict != nil
        }
        .onChange(of: isActive) {
            showingConflict = isActive && calibration.pendingConflict != nil
        }
        .alert("Anchors disagree", isPresented: $showingConflict, presenting: calibration.pendingConflict) { conflict in
            if calibration.aligned {
                Button("Keep current calibration", role: .cancel) { calibration.keepCurrentCalibration() }
            } else {
                Button("Cancel calibration", role: .cancel) { calibration.invalidate("Calibration cancelled. Choose a reference anchor to try again.") }
            }
            ForEach(conflict.choices, id: \.self) { id in
                Button("Erase and calibrate from " + id, role: .destructive) {
                    do { try calibration.eraseAndRecalibrate(using: id) }
                    catch { failure = error.localizedDescription; showingConflict = true }
                }
            }
        } message: { conflict in
            Text(conflict.description)
        }
    }
}

struct VisualAnchorCalibrationView: View {
    @Bindable var embodiment: EmbodimentController
    let caller: ConnectionController
    @Environment(\.dismiss) private var dismiss
    @State private var mountedBoards = Set<String>()
    @State private var mountingConfirmed = false
    @State private var failure: String?
    @State private var preview: UIImage?
    @State private var captureStarted = false
    private var calibration: VisualAnchorCalibration { embodiment.localization.visualCalibration }
    private var catalog: VisualAnchorCatalog? { embodiment.selectedLocalizationSpace?.anchor_boards }
    var body: some View {
        NavigationStack {
            Form {
                Section("Room and mounted anchors") {
                    Picker("Space", selection: $embodiment.selectedLocalizationSpaceID) {
                        Text("Select a space").tag("")
                        ForEach(embodiment.localizationSpaces) { Text($0.displayName).tag($0.space_id) }
                    }.accessibilityIdentifier("spatial.space")
                    if let catalog {
                        ForEach(catalog.boards, id: \.board_id) { board in
                            Toggle(board.board_id, isOn: Binding(
                                get: { mountedBoards.contains(board.board_id) },
                                set: { if $0 { mountedBoards.insert(board.board_id) } else { mountedBoards.remove(board.board_id) } }))
                        }
                        Text("Select only the anchors physically mounted in this room. One anchor is sufficient; additional visible anchors improve the joint pose estimate.")
                            .font(.footnote)
                        Toggle("Mounted positions and print scale match the room's anchor geometry", isOn: $mountingConfirmed)
                        Text("Saved installation coordinates are provisional. Verify the actual placement and print size before relying on room coordinates.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("No readable anchors for this room. Import its anchor manifest and grant anchor read access, then refresh.")
                    }
                    Button("Refresh anchors") { Task { await embodiment.loadLocalizationReferences(caller: caller) } }
                    if let message = embodiment.localizationReferenceMessage { Text(message).foregroundStyle(.red) }
                }
                Section("Face an anchor") {
                    Text("Hold the iPhone normally and point its rear camera at a selected anchor. Keep the printed tags clear and fully visible. Move a little sideways if the view is ambiguous.")
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 300)
                            .accessibilityLabel("Live rear camera view")
                    }
                    LabeledContent("DEVICE connection", value: embodiment.isOnline ? "Ready" : "Disconnected")
                    LabeledContent("Tracking", value: embodiment.localization.camera.tracking.reason)
                    Button(captureStarted ? "Restart visual calibration" : "Start visual calibration") { start() }
                        .accessibilityIdentifier("spatial.visual.capture")
                        .disabled(catalog == nil || mountedBoards.isEmpty || !mountingConfirmed || !embodiment.isOnline || !embodiment.localizationSelected)
                    if captureStarted {
                        Text(calibration.message)
                        LabeledContent("Anchors used", value: calibration.boardIDs.joined(separator: ", "))
                        LabeledContent("Tags in latest fit", value: String(calibration.tagCount))
                        if let rmse = calibration.reprojectionRMSE {
                            LabeledContent("Reprojection error", value: String(format: "%.2f px", rmse))
                        }
                    }
                    if let failure { Text(failure).foregroundStyle(.red) }
                }
                if calibration.enabled || calibration.aligned {
                    Section("Calibration status") {
                        AnchorCalibrationFeedback(calibration: calibration)
                        LabeledContent("Active reference anchors", value: calibration.activeBoardIDs.joined(separator: ", "))
                    }
                }
                if let pose = calibration.cameraPose {
                    Section("Room pose · 6 DOF") {
                        VisualPoseReadout(pose: pose)
                        Text("Origin: rear camera optical center. ARKit carries the room alignment while you move. Facing more mounted anchors refines it. Tracking resets require recalibration.")
                            .font(.footnote)
                        Text("Accuracy is unvalidated. Reprojection error measures image fit, not physical position error. This position is the rear camera's location, separate from the phone's center.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Visual Anchor Calibration")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onChange(of: embodiment.selectedLocalizationSpaceID) {
                mountedBoards = []; mountingConfirmed = false; captureStarted = false
                calibration.invalidate("Room changed. Select its mounted anchors and calibrate.")
            }
            .onChange(of: mountedBoards) {
                if captureStarted { captureStarted = false; calibration.invalidate("Anchor selection changed. Start calibration again.") }
            }
            .onChange(of: mountingConfirmed) {
                if !mountingConfirmed && captureStarted {
                    captureStarted = false; calibration.invalidate("Confirm physical mounting before calibration.")
                }
            }
            .task {
                await embodiment.loadLocalizationReferences(caller: caller)
                while !Task.isCancelled {
                    if embodiment.localization.camera.tracking.running,
                       let image = try? await embodiment.localization.camera.tracking.previewImage() {
                        preview = UIImage(data: image.jpeg)
                    } else { preview = nil }
                    do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                }
            }
        }
    }
    private func start() {
        failure = nil
        guard mountingConfirmed, let catalog, let session = embodiment.connection.session?.sessionID else { return }
        do {
            try calibration.begin(catalog: catalog, selectedBoards: mountedBoards, deviceSession: session)
            captureStarted = true
        } catch { failure = error.localizedDescription }
    }
}
