import Foundation
import Observation

/// Persistent DEVICE identity and local participation; never owns CALLER authority.
@MainActor @Observable
final class EmbodimentController {
    let vision: VisionRuntime
    let motion = MotionOrientationRuntime()
    let localization: LocalizationRuntime
    let inspection: InspectionPublisher
    let observations: ObservationSessionManager
    let connection: ConnectionController
    private(set) var runtimeEnabled = false
    private(set) var error: ClientFailure?
    var onboarding: EmbodimentOnboardingState = .notConfigured
    private(set) var setupOptions: EmbodimentSetupOptions?
    private(set) var serverConfiguration: EmbodimentConfiguration?
    private(set) var localizationReferencePersonID: String?
    private(set) var pendingReferenceSave: PendingReferenceSave?
    private(set) var localizationSpaces: [LocalizationSpaceOption] = []
    private(set) var localizationReferenceMessage: String?
    var selectedLocalizationSpaceID = "" {
        didSet {
            if let body = embodimentID { preferences.set(selectedLocalizationSpaceID, .space, body: body) }
        }
    }
    var selectedLocalizationSpace: LocalizationSpaceOption? {
        localizationSpaces.first { $0.space_id == selectedLocalizationSpaceID }
    }
    var selectedAgentID = ""
    var selectedCamera = true
    var selectedMotion = false
    private(set) var setupMessage: String?
    @ObservationIgnored private let preferences: EmbodimentPreferences
    @ObservationIgnored private var setupAttempt: EmbodimentSetupAttempt?
    private(set) var setupRecovery = EmbodimentSetupRecovery.resume
    @ObservationIgnored private var runtimeSelection = EmbodimentRuntimeSelection.stopped
    @ObservationIgnored private let store: any DeviceCredentialStoring
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private var generation = 0
    private var retainedBody: String?

    init(store: any DeviceCredentialStoring = KeychainCredentialStore(purpose: .device),
         factory: ConnectionController.TransportFactory? = nil, preferences: UserDefaults = .standard) {
        self.preferences = EmbodimentPreferences(storage: preferences)
        self.store = store
        let camera = NativeStillImageCapture()
        localization = LocalizationRuntime(camera: camera)
        let vision = VisionRuntime(camera: camera)
        self.vision = vision
        inspection = InspectionPublisher(camera: camera)
        observations = ObservationSessionManager(camera: camera)
        connection = ConnectionController(store: store, purpose: .device, automaticallyConnect: false, manifestProvider: { vision.manifest }, factory: factory)
        retainedBody = try? store.retainedEmbodiment()
        if let body = retainedBody ?? connection.credential?.embodimentID {
            pendingReferenceSave = self.preferences.load(PendingReferenceSave.self, .pendingReference, body: body)
        }
        setupAttempt = self.preferences.load(EmbodimentSetupAttempt.self, .attempt)
        if let body = connection.credential?.embodimentID {
            serverConfiguration = self.preferences.load(EmbodimentConfiguration.self, .configuration, body: body)
        }
        do { runtimeEnabled = try store.runtimeEnabled() }
        catch { self.error = error as? ClientFailure ?? .invalidCertificate }
        vision.configured = cameraSelected
    }
    var embodimentID: String? { connection.credential?.embodimentID ?? retainedBody }
    var isEnabled: Bool { embodimentID != nil }
    var isOnline: Bool { runtimeEnabled && connection.displayedState == .connected }

    var hasSavedSetup: Bool { setupAttempt != nil }
    var canStartNewAttempt: Bool { setupAttempt == nil || setupRecovery == .expired }
    var cameraSelected: Bool {
        guard let body = embodimentID,
              serverConfiguration?.cameraEnabled ?? (connection.credential?.visionObserveGranted == true) else { return false }
        return preferences.selected(.camera, body: body)
    }
    var motionSelected: Bool {
        guard let body = embodimentID, serverConfiguration?.motionEnabled == true else { return false }
        return preferences.selected(.motion, body: body)
    }
    var localizationSelected: Bool {
        guard let body = embodimentID, serverConfiguration?.localizationEnabled == true else { return false }
        return preferences.selected(.localization, body: body)
    }
    var agentName: String { serverConfiguration?.agent_display_name ?? "Loading…" }

    func loadSetup(caller: ConnectionController) async {
        guard !onboarding.busy else { return }
        onboarding = .loadingOptions
        setupMessage = nil
        setupRecovery = .resume
        do {
            let (transport, session, credential) = try caller.embodimentSetupAccess()
            setupOptions = try JSONDecoder().decode(EmbodimentSetupOptions.self,
                from: await transport.send("/embodiments/setup-options", sessionID: session))
            if let attempt = setupAttempt {
                guard attempt.clientID == credential.clientID, attempt.origin == transport.origin.absoluteString else {
                    throw EmbodimentSetupFailure(message: "Sign in with the account that started this setup, or start a new attempt.")
                }
                selectedAgentID = attempt.agent_id
                selectedMotion = attempt.diagnostics?.contains("orientation.local") == true
                selectedCamera = attempt.capabilities.contains("vision.observe")
                onboarding = .confirming
            } else {
                selectedAgentID = setupOptions?.eligible_agents.first?.agent_id ?? ""
                selectedCamera = setupOptions?.cameraAllowed == true
                onboarding = .selectingAgent
            }
        } catch { failSetup(error) }
    }
    func startNewAttempt() {
        guard !onboarding.busy, canStartNewAttempt else { return }
        setupAttempt = nil
        preferences.remove(.attempt)
        onboarding = .notConfigured
        setupMessage = nil
        setupRecovery = .resume
    }
    func refreshConfiguration(caller: ConnectionController) async {
        guard let body = embodimentID else { return }
        do {
            let (transport, session, _) = try caller.embodimentSetupAccess()
            let configuration = try JSONDecoder().decode(EmbodimentConfiguration.self,
                from: await transport.send("/embodiments/" + body, sessionID: session))
            try applyConfiguration(configuration, expectedBody: body)
            reconcileRuntimes()
            if connection.credential != nil { setupAttempt = nil; preferences.remove(.attempt) }
        } catch { setupMessage = error.localizedDescription }
        await loadLocalizationReferences(caller: caller)
    }
    func loadLocalizationReferences(caller: ConnectionController) async {
        guard let body = embodimentID else { return }
        do {
            let (transport, session, _) = try caller.embodimentSetupAccess()
            let catalog = try JSONDecoder().decode(LocalizationReferenceCatalog.self,
                from: await transport.send("/embodiments/" + body + "/localization-references", sessionID: session))
            guard body == embodimentID else { return }
            localizationReferencePersonID = catalog.person_id
            localizationSpaces = catalog.spaces.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            if selectedLocalizationSpaceID.isEmpty {
                selectedLocalizationSpaceID = preferences.string(.space, body: body) ?? ""
            }
            localizationReferenceMessage = nil
            if localization.calibration.reference == nil,
               let id = preferences.string(.reference, body: body),
               let space = selectedLocalizationSpace,
               let reference = space.references.first(where: { $0.id == id }) {
                localization.calibration.referenceSaved(reference, spaceID: space.space_id)
                localization.calibration.invalidate("Your reference is saved. Return to its fixed placement to relocalize.")
            }
        } catch {
            localizationSpaces = []
            localizationReferenceMessage = "Household references are unavailable. Reconnect and refresh."
        }
    }
    func rememberLocalizationReference(_ reference: LocalizationReferenceOption, spaceID: String) {
        selectedLocalizationSpaceID = spaceID
        if let body = embodimentID { preferences.set(reference.id, .reference, body: body) }
        localization.calibration.referenceSaved(reference, spaceID: spaceID)
    }
    func saveLocalizationReference(_ reference: LocalizationReferenceOption, spaceID: String,
                                   expectedRevision: Int, frameDefinition: JSONValue?, caller: ConnectionController) async throws -> LocalizationReferenceOption {
        guard let body = embodimentID else { throw ClientFailure.configuration }
        let (transport, session, _) = try caller.embodimentSetupAccess()
        let pending = PendingReferenceSave(spaceID: spaceID, reference: reference, expectedRevision: expectedRevision, frameDefinition: frameDefinition)
        try preferences.save(pending, .pendingReference, body: body)
        pendingReferenceSave = pending
        let anchor = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(reference))
        var payload: [String:JSONValue] = ["anchor": anchor, "expected_revision": .integer(Int64(expectedRevision))]
        if let frameDefinition { payload["frame_definition"] = frameDefinition }
        let data = try await transport.send("/embodiments/" + body + "/localization-references/" + spaceID,
            sessionID: session, method: "PUT", body: JSONEncoder().encode(JSONValue.object(payload)))
        guard body == embodimentID else { throw ClientFailure.configuration }
        let saved = try JSONDecoder().decode(LocalizationReferenceOption.self, from: data)
        pendingReferenceSave = nil
        preferences.remove(.pendingReference, body: body)
        rememberLocalizationReference(saved, spaceID: spaceID)
        await loadLocalizationReferences(caller: caller)
        return saved
    }
    func confirmSetup(caller: ConnectionController) async {
        guard !onboarding.busy, connection.credential == nil else { return }
        do {
            let (transport, session, credential) = try caller.embodimentSetupAccess()
            guard setupOptions?.eligible_agents.contains(where: { $0.agent_id == selectedAgentID }) == true,
                  !selectedCamera || setupOptions?.cameraAllowed == true,
                  !selectedMotion || setupOptions?.motionAllowed == true else { throw ClientFailure.configuration }
            let attempt = setupAttempt ?? EmbodimentSetupAttempt(agentID: selectedAgentID, camera: selectedCamera, motion: selectedMotion,
                clientID: credential.clientID, origin: transport.origin)
            guard attempt.clientID == credential.clientID, attempt.origin == transport.origin.absoluteString else { throw ClientFailure.configuration }
            setupAttempt = attempt
            try preferences.save(attempt, .attempt)
            setupMessage = nil
            setupRecovery = .resume
            onboarding = .requestingPermissions
            if attempt.capabilities.contains("vision.observe") { await vision.requestPermission() }
            onboarding = .enrolling
            // Send only the application schema, never client-supplied V1 grants.
            let body = try JSONEncoder().encode(JSONValue.object([
                "enrollment_id": .string(attempt.enrollment_id), "agent_id": .string(attempt.agent_id),
                "capabilities": .array(attempt.capabilities.map(JSONValue.string)),
                "diagnostics": .array((attempt.diagnostics ?? []).map(JSONValue.string))]))
            let result = try JSONValue.decode(await transport.send("/embodiments/enrollments", sessionID: session, method: "POST", body: body))
            let fields = try result.object(required: ["enrollment_id", "embodiment_id", "status", "invitation"])
            guard try fields.field("enrollment_id") == .string(attempt.enrollment_id) else { throw ClientFailure.invalidResponse }
            let invitation = try JSONEncoder().encode(fields.field("invitation"))
            let profile = LoginProfile(configuration: credential.configuration, caPEM: credential.trustedCAPEM)
            onboarding = .creatingDeviceKey
            await provision(invitation, profile: profile)
            guard connection.credential != nil else {
                throw error ?? ClientFailure.transport
            }
            setupAttempt = nil
            preferences.remove(.attempt)
            await refreshConfiguration(caller: caller)
            onboarding = .registering
        } catch { failSetup(error) }
    }
    func changeCamera(_ enabled: Bool, caller: ConnectionController) async {
        guard let body = embodimentID, !onboarding.busy else { return }
        onboarding = .requestingPermissions
        if !enabled { preferences.set(false, .camera, body: body); reconcileRuntimes() }
        do {
            if enabled { await vision.requestPermission() }
            let (transport, session, _) = try caller.embodimentSetupAccess()
            let data = try JSONEncoder().encode(["capabilities": EmbodimentSetupAttempt.capabilities(camera: enabled)])
            let configuration = try JSONDecoder().decode(EmbodimentConfiguration.self,
                from: await transport.send("/embodiments/" + body, sessionID: session, method: "PATCH", body: data))
            stopAllRuntimes()
            await connection.disconnect()
            try applyConfiguration(configuration, expectedBody: body)
            preferences.set(enabled, .camera, body: body)
            if runtimeEnabled { enableRuntime() } else { reconcileRuntimes() }
            setupMessage = nil
            setupRecovery = .resume
            onboarding = .enabled
        } catch { failSetup(error) }
    }
    func changeMotion(_ enabled: Bool, caller: ConnectionController) async {
        guard let body = embodimentID, !onboarding.busy else { return }
        onboarding = .enrolling
        // OFF immediately stops local work even if the server cannot be reached.
        if !enabled { preferences.set(false, .motion, body: body); reconcileRuntimes() }
        do {
            let (transport, session, _) = try caller.embodimentSetupAccess()
            let payload = JSONValue.object([
                "capabilities": .array(EmbodimentSetupAttempt.capabilities(camera: cameraSelected).map(JSONValue.string)),
                "diagnostics": .array(updatedDiagnostics("orientation.local", enabled: enabled).map(JSONValue.string))])
            let configuration = try JSONDecoder().decode(EmbodimentConfiguration.self,
                from: await transport.send("/embodiments/" + body, sessionID: session, method: "PATCH", body: JSONEncoder().encode(payload)))
            stopAllRuntimes()
            await connection.disconnect()
            try applyConfiguration(configuration, expectedBody: body)
            preferences.set(enabled, .motion, body: body)
            if runtimeEnabled { enableRuntime() } else { reconcileRuntimes() }
            setupMessage = nil; onboarding = .enabled
        } catch { failSetup(error) }
    }
    private func updatedDiagnostics(_ name: String, enabled: Bool) -> [String] {
        var values = Set(serverConfiguration?.diagnostics ?? [])
        if enabled { values.insert(name) } else { values.remove(name) }
        return values.sorted()
    }
    func changeLocalization(_ enabled: Bool, caller: ConnectionController) async {
        guard let body = embodimentID, !onboarding.busy else { return }
        onboarding = .requestingPermissions
        if !enabled { preferences.set(false, .localization, body: body); reconcileRuntimes() }
        do {
            if enabled { await vision.requestPermission() }
            let (transport, session, _) = try caller.embodimentSetupAccess()
            let payload = JSONValue.object([
                "capabilities": .array(EmbodimentSetupAttempt.capabilities(camera: cameraSelected).map(JSONValue.string)),
                "diagnostics": .array(updatedDiagnostics("localization.local", enabled: enabled).map(JSONValue.string))])
            let configuration = try JSONDecoder().decode(EmbodimentConfiguration.self,
                from: await transport.send("/embodiments/" + body, sessionID: session, method: "PATCH", body: JSONEncoder().encode(payload)))
            stopAllRuntimes()
            await connection.disconnect()
            try applyConfiguration(configuration, expectedBody: body)
            preferences.set(enabled, .localization, body: body)
            if runtimeEnabled { enableRuntime() } else { reconcileRuntimes() }
            setupMessage = nil; onboarding = .enabled
        } catch { failSetup(error) }
    }
    func auditRuntime(caller: ConnectionController) async {
        guard let body = embodimentID else { return }
        do {
            let (transport, session, _) = try caller.embodimentSetupAccess()
            _ = try await transport.send("/embodiments/" + body + "/runtime", sessionID: session, method: "POST",
                body: JSONEncoder().encode(["enabled": runtimeEnabled]))
        } catch { setupMessage = "Runtime changed on this phone. Home Cortex could not record the change yet." }
    }
    private func failSetup(_ error: any Error) {
        setupRecovery = (error as? EmbodimentSetupFailure)?.recovery ?? .resume
        setupMessage = error.localizedDescription
        onboarding = .failed(error.localizedDescription)
    }

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
                stopAllRuntimes()
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
            reconcileRuntimes()
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
            reconcileRuntimes()
        } catch { self.error = error as? ClientFailure ?? .invalidCertificate }
    }
    func disableRuntime() async {
        generation += 1
        stopAllRuntimes()
        // Stop local authority even if the preference write or network fails.
        runtimeEnabled = false
        do { try store.storeRuntimeEnabled(false); error = nil }
        catch { self.error = error as? ClientFailure ?? .invalidCertificate }
        await connection.disconnect()
    }
    func setForeground(_ active: Bool) {
        foreground = active
        if active { observations.reapExpired() }
        if !active { generation += 1; stopAllRuntimes() }
        connection.setForeground(active)
        if active && runtimeEnabled && connection.state == .disconnected { connection.connect() }
        reconcileRuntimes()
    }
    private func applyConfiguration(_ configuration: EmbodimentConfiguration, expectedBody: String) throws {
        guard embodimentID == expectedBody, configuration.embodiment_id == expectedBody else { throw ClientFailure.invalidResponse }
        if connection.credential != nil { try connection.updateDeviceCameraGrant(configuration.cameraEnabled) }
        try preferences.save(configuration, .configuration, body: expectedBody)
        serverConfiguration = configuration
        vision.configured = cameraSelected
    }

    private func stopAllRuntimes() {
        observations.interrupt()
        inspection.stop(); vision.stop(); motion.stop(); localization.stop()
        runtimeSelection = .stopped
    }

    func reconcileRuntimes() {
        let next = EmbodimentRuntimeSelection(foreground: foreground, enabled: runtimeEnabled,
            credentialAvailable: connection.credential != nil, camera: cameraSelected,
            motion: motionSelected, localization: localizationSelected)
        vision.configured = cameraSelected
        motion.configured = motionSelected
        localization.configured = localizationSelected
        if next.camera { vision.start(connection: connection); inspection.start(connection: connection) }
        else if runtimeSelection.camera { observations.interrupt(); inspection.stop(); vision.stop() }
        if next.motion { motion.start(connection: connection) }
        else if runtimeSelection.motion { motion.stop() }
        if next.localization { localization.start(connection: connection) }
        else if runtimeSelection.localization { localization.stop() }
        runtimeSelection = next
    }

    func reportImportError(_ error: any Error) { self.error = error as? ClientFailure ?? .invalidInvitation }
}
