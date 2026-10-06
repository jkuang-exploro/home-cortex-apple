import SwiftUI
import UniformTypeIdentifiers

struct ConnectionView: View {
    @Bindable var connection: ConnectionController
    @State private var importing: ImportKind?
    @State private var showImporter = false
    @State private var confirmForget = false
    private let metadata = AppMetadata()

    private enum ImportKind { case configuration, ca, invitation }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label("Home Cortex", systemImage: "house.fill")
                        .font(.largeTitle.bold())
                        .accessibilityIdentifier("connection.title")

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connection").font(.subheadline).foregroundStyle(.secondary)
                        Label(connection.displayedState.label, systemImage: connection.displayedState == .connected ? "checkmark.circle.fill" : "circle")
                            .font(.title2.bold())
                            .foregroundStyle(connection.displayedState == .connected ? Color.green : Color.primary)
                            .accessibilityIdentifier("connection.state")
                        if case .failed(let failure) = connection.state {
                            Text(failure.localizedDescription).font(.callout).foregroundStyle(.secondary)
                                .accessibilityIdentifier("connection.error")
                        } else if connection.credential == nil {
                            Text("This device is not provisioned.").foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        detail("Server", connection.configuration?.serverHostname ?? "Not configured", id: "connection.server")
                        detail("Protocol", connection.configuration?.protocolVersion ?? "Not configured", id: "connection.protocol")
                        detail("Discovery", discoveryLabel, id: "connection.discovery")
                        Divider()
                        detail("Client", connection.credential?.clientID ?? "Not provisioned", id: "connection.client")
                        detail("Provisioning", connection.provisioning.label, id: "connection.provisioning")
                        detail("Role", "Software client", id: "connection.role")
                        detail("Session", connection.displayedState == .connected ? "Active" : "Not active", id: "connection.session")
                        detail("Embodiment", "Not enabled", id: "connection.embodiment")
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))

                    if connection.credential == nil {
                        if connection.configuration == nil {
                            Button("Import server configuration") { beginImport(.configuration) }
                                .buttonStyle(.borderedProminent)
                        }
                        Button(connection.trustedCAAvailable ? "Replace public CA" : "Import public CA") { beginImport(.ca) }
                            .buttonStyle(.bordered)
                            .disabled(connection.busy)
                        Button("Provision Client") { beginImport(.invitation) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!connection.canProvision)
                            .accessibilityIdentifier("connection.provision")
                        Text("Import the public CA and a software-client invitation through an operator-controlled channel. Your private key is generated on this device.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        if [.connected, .reconnecting, .discovering, .authenticating, .registering].contains(connection.state) {
                            Button("Disconnect") { Task { await connection.disconnect() } }
                                .buttonStyle(.bordered)
                        } else {
                            Button("Connect") { connection.connect() }
                                .buttonStyle(.borderedProminent)
                                .disabled(connection.credential?.authenticationRejected == true || (connection.credential?.expiresAt ?? .distantPast) <= Date())
                                .accessibilityIdentifier("connection.connect")
                        }
                        Button("Forget credential and re-provision", role: .destructive) { confirmForget = true }
                            .font(.footnote)
                    }

                    if connection.credential == nil {
                        HStack {
                            Button("Check discovery") { Task { await connection.discover() } }
                                .disabled(connection.busy || connection.configuration == nil || !connection.trustedCAAvailable)
                            Spacer()
                            Button("Server settings") { beginImport(.configuration) }.disabled(connection.busy)
                        }.font(.footnote)
                    }
                    Text(metadata.versionDescription).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("connection.version")
                }
                .padding(24)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
        }
        .tint(Color(red: 0.08, green: 0.45, blue: 0.43))
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importing == .ca ? [.data, .plainText] : [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (attributes.fileSize ?? 0) <= 131_072 else { throw ClientFailure.configuration }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                let data = try file.read(upToCount: 131_073) ?? Data()
                guard data.count <= 131_072 else { throw ClientFailure.configuration }
                switch importing {
                case .configuration: try connection.importConfiguration(data)
                case .ca: try connection.importCA(data)
                case .invitation: Task { await connection.provision(invitationData: data) }
                case nil: break
                }
            } catch {
                if (error as NSError).code != CocoaError.userCancelled.rawValue { connection.reportImportError(error) }
            }
            importing = nil
        }
        .alert("Forget this client credential?", isPresented: $confirmForget) {
            Button("Cancel", role: .cancel) { }
            Button("Forget", role: .destructive) { Task { await connection.forgetCredential() } }
        } message: {
            Text("This removes the device-held key and credential. A new operator invitation is required. Server-side revocation remains an operator action.")
        }
    }

    private var discoveryLabel: String {
        switch connection.discovery {
        case .unknown: "Not checked"
        case .discovering: "Checking server"
        case .compatible: "Compatible · last discovery verified"
        case .incompatible: "Protocol unsupported"
        case .failed: "Failed"
        }
    }
    private func detail(_ title: String, _ value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.headline).textSelection(.enabled).accessibilityIdentifier(id)
        }
    }
    private func beginImport(_ kind: ImportKind) { importing = kind; showImporter = true }
}
