import SwiftUI
import UniformTypeIdentifiers

struct EmbodimentView: View {
    @Bindable var embodiment: EmbodimentController
    var caller: ConnectionController? = nil
    @State private var setup = false
    @State private var recovery = false
    @State private var replacing = false
    @State private var selectInvitation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Embodiment").font(.title2.bold())
            if embodiment.isEnabled {
                Text("This iPhone").font(.headline).accessibilityIdentifier("embodiment.identity")
                LabeledContent("Agent", value: embodiment.agentName)
                Toggle("Embodiment Enabled", isOn: Binding(get: { embodiment.runtimeEnabled }, set: { enabled in
                    Task {
                        if enabled { embodiment.enableRuntime() } else { await embodiment.disableRuntime() }
                        if let caller { await embodiment.auditRuntime(caller: caller) }
                    }
                }))
                Text("Turning this off retains your phone’s identity, agent, and sensor choices.").font(.footnote).foregroundStyle(.secondary)
                Toggle("Camera", isOn: Binding(get: { embodiment.cameraSelected }, set: { enabled in
                    if let caller { Task { await embodiment.changeCamera(enabled, caller: caller) } }
                })).disabled(caller?.displayedState != .connected || embodiment.onboarding.busy)
                if embodiment.cameraSelected {
                    LabeledContent("Camera access", value: embodiment.vision.camera.permissionLabel)
                    if embodiment.vision.camera.availability != nil {
                        Text("Camera is selected but currently unavailable. Allow camera access in Settings to use it.").font(.footnote)
                        Button("Open iPhone Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }
                Toggle("Visual-inertial localization", isOn: Binding(get: { embodiment.localizationSelected }, set: { enabled in
                    if let caller { Task { await embodiment.changeLocalization(enabled, caller: caller) } }
                })).disabled(caller?.displayedState != .connected || embodiment.onboarding.busy)
                    .accessibilityIdentifier("embodiment.localization")
                Text("Uses the rear camera and motion continuously while this app is open to track movement. Camera evidence and Motion diagnostics have separate controls.").font(.footnote).foregroundStyle(.secondary)
                if embodiment.localizationSelected {
                    LabeledContent("Localization", value: embodiment.localization.camera.tracking.state.rawValue)
                    Text(embodiment.localization.camera.tracking.reason).font(.footnote)
                    Text("Household pose unavailable: measured camera/body geometry and validated uncertainty are required.").font(.footnote)
                    DisclosureGroup("Household calibration") {
                        Picker("Room", selection: $embodiment.selectedLocalizationSpaceID) {
                            Text("Select a room").tag("")
                            ForEach(embodiment.localizationSpaces) { space in
                                Text(space.displayName).tag(space.space_id)
                            }
                        }.accessibilityIdentifier("embodiment.localization.room")
                        if let space = embodiment.selectedLocalizationSpace {
                            LabeledContent("Surveyed coordinate frame", value: space.coordinate_ready ? "Available" : "Required")
                            if space.references.isEmpty {
                                Text("Mark and measure the room origin and axes, then survey a repeatable phone placement with full position and orientation.").font(.footnote)
                            }
                            ForEach(space.references) { reference in
                                Text("\(reference.id) · revision \(reference.reference.revision)").font(.headline)
                                Text(reference.reference.placement_instructions).font(.footnote)
                                Text(reference.reference.measurement_notes).font(.footnote).foregroundStyle(.secondary)
                            }
                            Text("Calibration requires measured camera/body geometry and an independently validated accuracy profile.").font(.footnote)
                        }
                        if let message = embodiment.localizationReferenceMessage { Text(message).font(.footnote) }
                        Button("Refresh references") {
                            if let caller { Task { await embodiment.loadLocalizationReferences(caller: caller) } }
                        }.disabled(caller?.displayedState != .connected)
                    }
                }
                if let caller { SpatialAwarenessView(embodiment: embodiment, caller: caller) }
                Toggle("Motion & Orientation", isOn: Binding(get: { embodiment.motionSelected }, set: { enabled in
                    if let caller { Task { await embodiment.changeMotion(enabled, caller: caller) } }
                })).disabled(caller?.displayedState != .connected || embodiment.onboarding.busy)
                    .accessibilityIdentifier("embodiment.motion")
                if embodiment.motionSelected {
                    LabeledContent("Motion tracking", value: embodiment.motion.status)
                    Text("Local attitude only. Not household aligned. Runs while Home Cortex is open; device motion does not ask for an iOS permission prompt.").font(.footnote).foregroundStyle(.secondary)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    LabeledContent("Runtime") {
                        Label(embodiment.isOnline ? "Online" : "Offline", systemImage: embodiment.isOnline ? "circle.fill" : "circle")
                            .foregroundStyle(embodiment.isOnline ? .green : .secondary)
                            .accessibilityIdentifier("embodiment.runtime")
                    }
                }
                if embodiment.runtimeEnabled && !embodiment.isOnline {
                    Button("Reconnect") { embodiment.enableRuntime() }.disabled(embodiment.connection.busy)
                }
            } else {
                Text("Use This iPhone as an Embodiment").font(.headline)
                Text("Home Cortex can use this phone’s selected sensors as the physical senses of one of your agents.")
                Button(embodiment.hasSavedSetup ? "Resume Setup" : "Continue") {
                    setup = true
                    if let caller { Task { await embodiment.loadSetup(caller: caller) } }
                }.buttonStyle(.borderedProminent)
                    .disabled(caller?.displayedState != .connected)
                    .accessibilityIdentifier("embodiment.enable")
                if caller?.displayedState != .connected { Text("Connect Home Cortex to set up this phone.").font(.footnote) }
            }
            if let message = embodiment.setupMessage { Text(message).font(.footnote).foregroundStyle(.red) }
            if let error = embodiment.error { Text(error.localizedDescription).foregroundStyle(.red) }
            if case .failed(let error) = embodiment.connection.state { Text(error.localizedDescription).foregroundStyle(.red) }
            #if DEBUG
            DisclosureGroup("Developer / Recovery Provisioning", isExpanded: $recovery) {
                Button("Import DEVICE invitation") { replacing = embodiment.connection.credential != nil; selectInvitation = true }
                if embodiment.isEnabled {
                    Text(embodiment.embodimentID ?? "").font(.caption.monospaced())
                    LabeledContent("Developer preview", value: embodiment.inspection.status)
                    Toggle("Pause Developer Preview", isOn: Binding(get: { embodiment.inspection.paused }, set: {
                        embodiment.inspection.paused = $0
                        embodiment.inspection.stop()
                        if embodiment.isOnline && !$0 { embodiment.inspection.start(connection: embodiment.connection) }
                    }))
                }
            }
            #endif
        }.padding(24).frame(maxWidth: 600, alignment: .leading)
        .task(id: caller?.displayedState == .connected) {
            if let caller, caller.displayedState == .connected, embodiment.isEnabled { await embodiment.refreshConfiguration(caller: caller) }
        }
        .sheet(isPresented: $setup) {
            if let caller { EmbodimentSetupSheet(embodiment: embodiment, caller: caller) }
        }
        .fileImporter(isPresented: $selectInvitation, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let data = try file.read(upToCount: 131_073) ?? Data()
                guard data.count <= 131_072 else { throw ClientFailure.invalidInvitation }
                Task { await embodiment.provision(data, replacing: replacing) }
            } catch { embodiment.reportImportError(error) }
        }
    }
}

private struct EmbodimentSetupSheet: View {
    @Bindable var embodiment: EmbodimentController
    let caller: ConnectionController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                switch embodiment.onboarding {
                case .selectingAgent:
                    Section("Choose Agent") {
                        ForEach(embodiment.setupOptions?.eligible_agents ?? []) { agent in
                            Button { embodiment.selectedAgentID = agent.agent_id } label: {
                                HStack { Text(agent.display_name); Spacer(); if embodiment.selectedAgentID == agent.agent_id { Image(systemName: "checkmark") } }
                            }
                        }
                        Button("Continue") { embodiment.onboarding = .selectingSensors }.disabled(embodiment.selectedAgentID.isEmpty)
                    }
                case .selectingSensors:
                    Section("Choose Sensors") {
                        if embodiment.setupOptions?.cameraAllowed == true { Toggle("Camera", isOn: $embodiment.selectedCamera) }
                        if embodiment.setupOptions?.motionAllowed == true { Toggle("Motion & Orientation", isOn: $embodiment.selectedMotion) }
                        Text("Only sensors supported by this app and allowed by Home Cortex appear here.").font(.footnote)
                        Button("Continue") { embodiment.onboarding = .confirming }
                    }
                case .confirming:
                    Section("Use This iPhone") {
                        Text(embodiment.setupOptions?.eligible_agents.first(where: { $0.agent_id == embodiment.selectedAgentID })?.display_name ?? "")
                        LabeledContent("Camera", value: embodiment.selectedCamera ? "On" : "Off")
                        LabeledContent("Motion & Orientation", value: embodiment.selectedMotion ? "On" : "Off")
                        Text("Motion measures local device attitude while this app is open. Household calibration is not available yet.").font(.footnote)
                        Text("Camera access lets your agent take a fresh photo when requested. iPhone will ask for permission next. You can continue if access is denied.")
                        Button("Confirm") { Task { await embodiment.confirmSetup(caller: caller) } }.buttonStyle(.borderedProminent)
                    }
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                    Button("Retry Saved Setup") { Task { await embodiment.loadSetup(caller: caller) } }
                    if embodiment.canStartNewAttempt {
                        Button("Start New Attempt") { embodiment.startNewAttempt(); Task { await embodiment.loadSetup(caller: caller) } }
                    }
                case .registering, .enabled:
                    Text(embodiment.isOnline ? "Embodiment Online" : "Setup complete. Connecting this iPhone…")
                    Button("Done") { dismiss() }
                case .notConfigured:
                    Button("Continue") { Task { await embodiment.loadSetup(caller: caller) } }
                default:
                    ProgressView(embodiment.onboarding == .requestingPermissions ? "Requesting sensor access…" : "Setting up this iPhone…")
                }
            }
            .navigationTitle("Embodiment").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(embodiment.onboarding.busy) } }
        }
    }
}
