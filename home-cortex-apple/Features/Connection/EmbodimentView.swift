import SwiftUI
import UniformTypeIdentifiers

struct EmbodimentView: View {
    @Bindable var embodiment: EmbodimentController
    @State private var explainEnable = false
    @State private var replaceCredential = false
    @State private var confirmDisable = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 16) {
                Text("This iPhone").font(.title2.bold())
                LabeledContent("Embodiment", value: embodiment.isEnabled ? "Enabled" : "Not enabled")
                    .accessibilityIdentifier("embodiment.identity")
                LabeledContent("Runtime") {
                    Label(embodiment.isOnline ? "Online" : "Offline", systemImage: embodiment.isOnline ? "circle.fill" : "circle")
                        .foregroundStyle(embodiment.isOnline ? .green : .secondary)
                        .accessibilityIdentifier("embodiment.runtime")
                }
                LabeledContent("Capabilities", value: embodiment.vision.configured ? "vision.observe" : "None yet")
                if embodiment.isEnabled {
                    if !embodiment.vision.configured {
                        Button("Upgrade Vision Access") { replaceCredential = true; explainEnable = true }.disabled(embodiment.connection.busy)
                        Text("Import a new DEVICE invitation for this same phone. Only vision.observe is added; chat keeps its identity.").font(.footnote)
                    } else {
                        LabeledContent("Camera permission", value: embodiment.vision.camera.permissionLabel)
                        LabeledContent("Vision", value: embodiment.vision.camera.availability == nil ? "Available" : "Temporarily unavailable")
                        Button("Enable Camera") { Task { await embodiment.vision.requestPermission() } }
                        LabeledContent("Developer preview", value: embodiment.inspection.status)
                        Toggle("Pause Developer Preview", isOn: Binding(get: { embodiment.inspection.paused }, set: {
                            embodiment.inspection.paused = $0
                            embodiment.inspection.stop()
                            if embodiment.isOnline && !$0 { embodiment.inspection.start(connection: embodiment.connection) }
                        }))
                        Text("An authorized inspector can request temporary preview while this app is open. Preview frames are never evidence.").font(.footnote)
                        if let error = embodiment.vision.lastError { Text(error).font(.footnote).foregroundStyle(.red) }
                        if let timing = embodiment.vision.lastTiming { Text(timing).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let id = embodiment.embodimentID {
                    Text(id).font(.caption.monospaced()).textSelection(.enabled)
                    Text("This physical identity remains when offline. Chat retains its separate identity.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if embodiment.runtimeEnabled {
                        Button("Disable Embodiment Runtime", role: .destructive) { confirmDisable = true }
                            .accessibilityIdentifier("embodiment.disable")
                    } else {
                        Button("Enable Embodiment Runtime") { embodiment.enableRuntime() }
                            .accessibilityIdentifier("embodiment.resume")
                    }
                    if embodiment.runtimeEnabled && !embodiment.isOnline {
                        Button("Reconnect Runtime") { embodiment.enableRuntime() }
                            .disabled(embodiment.connection.busy || embodiment.connection.credential?.authenticationRejected == true)
                    }
                } else {
                    Button("Enable as Embodiment") { replaceCredential = false; explainEnable = true }
                        .buttonStyle(.borderedProminent).disabled(embodiment.connection.busy)
                        .accessibilityIdentifier("embodiment.enable")
                    Text("Optional. Chat uses a separate identity and continues independently.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if embodiment.connection.busy { ProgressView(embodiment.connection.provisioning.label) }
                if let error = embodiment.error { Text(error.localizedDescription).foregroundStyle(.red) }
                if case .failed(let error) = embodiment.connection.state {
                    Text(error.localizedDescription).foregroundStyle(.red)
                }
            }.padding(24).frame(maxWidth: 600, alignment: .leading)
        }
        .sheet(isPresented: $explainEnable) {
            EmbodimentEnableSheet(embodiment: embodiment, replacing: replaceCredential)
        }
        .alert("Disable embodiment runtime?", isPresented: $confirmDisable) {
            Button("Cancel", role: .cancel) { }
            Button("Disable Runtime", role: .destructive) { Task { await embodiment.disableRuntime() } }
        } message: {
            Text("Disconnects this phone’s DEVICE session. Its identity, association, and credential remain. Chat is unaffected.")
        }
    }
}

private struct EmbodimentEnableSheet: View {
    @Bindable var embodiment: EmbodimentController
    let replacing: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selectInvitation = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text("Enable this iPhone as an embodiment").font(.title2.bold())
                    .accessibilityIdentifier("embodiment.setup")
                Text(replacing ? "Select the operator’s vision.observe DEVICE invitation for this same phone. This replaces its local DEVICE credential with a new independent key. Camera access is requested separately." : "Select the operator’s DEVICE invitation to create a separate device key. The phone’s persistent identity is associated with 老管家. Camera access is requested separately.")
                Button("Import DEVICE invitation") { selectInvitation = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("embodiment.import")
                Text("Chat keeps its existing identity. You can disable this phone’s runtime later without deleting its identity.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
            }.padding(24)
            .navigationTitle("Enable Embodiment").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
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
                dismiss()
                Task { await embodiment.provision(data, replacing: replacing) }
            } catch {
                if (error as NSError).code != CocoaError.userCancelled.rawValue {
                    embodiment.reportImportError(error)
                    dismiss()
                }
            }
        }
    }
}
