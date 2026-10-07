import Foundation
import Observation

/// Persistent DEVICE identity and local participation; never owns CALLER authority.
@MainActor @Observable
final class EmbodimentController {
    let vision: VisionRuntime
    let inspection: InspectionPublisher
    let connection: ConnectionController
    private(set) var runtimeEnabled = false
    private(set) var error: ClientFailure?
    @ObservationIgnored private let store: any DeviceCredentialStoring
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var generation = 0
    private var retainedBody: String?

    init(store: any DeviceCredentialStoring = KeychainCredentialStore(purpose: .device),
         factory: ConnectionController.TransportFactory? = nil) {
        self.store = store
        let camera = NativeStillImageCapture()
        let vision = VisionRuntime(camera: camera)
        self.vision = vision
        inspection = InspectionPublisher(camera: camera)
        connection = ConnectionController(store: store, purpose: .device, automaticallyConnect: false, manifestProvider: { vision.manifest }, factory: factory)
        retainedBody = try? store.retainedEmbodiment()
        vision.configured = connection.credential?.visionObserveGranted == true
        do { runtimeEnabled = try store.runtimeEnabled() }
        catch { self.error = error as? ClientFailure ?? .invalidCertificate }
    }
    var embodimentID: String? { connection.credential?.embodimentID ?? retainedBody }
    var isEnabled: Bool { embodimentID != nil }
    var isOnline: Bool { runtimeEnabled && connection.displayedState == .connected }

    /// Called only after explicit Enable and invitation selection in the UI.
    func provision(_ data: Data, profile: LoginProfile? = nil, replacing: Bool = false) async {
        guard (connection.credential == nil || replacing), !connection.busy else { return }
        generation += 1
        let token = generation
        error = nil
        do {
            let profile = try profile ?? LoginProfile.bundled()
            let invitation = try ProvisioningInvitation(data: data, configuration: profile.configuration, purpose: .device)
            if replacing {
                guard invitation.visionObserveGranted, invitation.embodimentID == embodimentID else { throw ClientFailure.invalidInvitation }
                if let body = embodimentID { try store.storeRetainedEmbodiment(body); retainedBody = body }
                inspection.stop(); vision.stop()
                vision.configured = false
                await connection.forgetCredential()
                guard connection.credential == nil else { throw ClientFailure.invalidCertificate }
            }
            try connection.importConfiguration(JSONEncoder().encode(profile.configuration))
            try connection.importCA(Data(profile.caPEM.utf8))
            await connection.provision(invitationData: data, connectAfterProvisioning: false)
            guard token == generation, foreground, connection.credential != nil else { return }
            if let body = connection.credential?.embodimentID { try store.storeRetainedEmbodiment(body); retainedBody = body }
            try store.storeRuntimeEnabled(true)
            runtimeEnabled = true
            vision.configured = connection.credential?.visionObserveGranted == true
            connection.connect()
            vision.start(connection: connection)
            inspection.start(connection: connection)
        } catch { self.error = error as? ClientFailure ?? .invalidInvitation }
    }
    func enableRuntime() {
        guard isEnabled else { return }
        do {
            try store.storeRuntimeEnabled(true)
            runtimeEnabled = true
            error = nil
            connection.setForeground(foreground)
            connection.connect()
            if foreground { vision.start(connection: connection); inspection.start(connection: connection) }
        } catch { self.error = error as? ClientFailure ?? .invalidCertificate }
    }
    func disableRuntime() async {
        generation += 1
        inspection.stop(); vision.stop()
        // Stop local authority even if the preference write or network fails.
        runtimeEnabled = false
        do { try store.storeRuntimeEnabled(false); error = nil }
        catch { self.error = error as? ClientFailure ?? .invalidCertificate }
        await connection.disconnect()
    }
    func setForeground(_ active: Bool) {
        foreground = active
        if !active { generation += 1; inspection.stop(); vision.stop() }
        connection.setForeground(active)
        if active && runtimeEnabled {
            if connection.state == .disconnected { connection.connect() }
            vision.start(connection: connection)
            inspection.start(connection: connection)
        }
    }
    func reportImportError(_ error: any Error) { self.error = error as? ClientFailure ?? .invalidInvitation }
}
