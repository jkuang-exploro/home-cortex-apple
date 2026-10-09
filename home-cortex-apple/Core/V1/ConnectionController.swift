import Foundation
import Observation
import OSLog

enum ProvisioningState: Equatable {
    case notProvisioned, invitationSelected, generatingKey, generatingCSR, enrolling, provisioned
    case failed(ClientFailure)

    var label: String {
        switch self {
        case .notProvisioned: "Not Provisioned"
        case .invitationSelected: "Invitation selected"
        case .generatingKey: "Generating device key"
        case .generatingCSR: "Generating CSR"
        case .enrolling: "Enrolling"
        case .provisioned: "Provisioned"
        case .failed: "Provisioning failed"
        }
    }
}

enum ConnectionState: Equatable {
    case unconfigured, provisioning, disconnected, discovering, authenticating, registering, connected, reconnecting
    case failed(ClientFailure)

    var label: String {
        switch self {
        case .unconfigured: "Not Provisioned"
        case .provisioning: "Provisioning"
        case .disconnected: "Disconnected"
        case .discovering: "Discovering"
        case .authenticating: "Authenticating"
        case .registering: "Registering"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .failed: "Connection failed"
        }
    }
}

@MainActor @Observable
final class ConnectionController {
    typealias TransportFactory = @MainActor (ClientConfiguration, String, CredentialMetadata?) throws -> any V1Transport
    private(set) var state: ConnectionState = .unconfigured
    private(set) var provisioning: ProvisioningState = .notProvisioned
    private(set) var maxMediaBytes = VisualEvidence.maxMediaBytes
    private(set) var discovery: DiscoveryState = .unknown
    private(set) var configuration: ClientConfiguration?
    private(set) var credential: CredentialMetadata?
    private(set) var session: SessionView?
    private(set) var trustedCAAvailable = false
    private(set) var lease: SessionLease?
    private(set) var signingIn = false
    let purpose: CredentialPurpose
    @ObservationIgnored private let store: any CredentialStoring
    @ObservationIgnored private var inspectionChannel: (String, any InspectionTransport)?
    @ObservationIgnored private let manifestProvider: @MainActor () -> JSONValue
    @ObservationIgnored private let factory: TransportFactory
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var wantsConnection = false
    @ObservationIgnored private var foreground = true
    @ObservationIgnored private let logger = Logger(subsystem: "HomeCortex", category: "V1Connection")

    init(store: any CredentialStoring = KeychainCredentialStore(), purpose: CredentialPurpose = .caller, automaticallyConnect: Bool = true, manifestProvider: (@MainActor () -> JSONValue)? = nil, factory: TransportFactory? = nil) {
        self.purpose = purpose
        self.manifestProvider = manifestProvider ?? { .object(["revision": .integer(1), "capabilities": .array([])]) }
        self.store = store
        self.factory = factory ?? { config, ca, metadata in
            try URLSessionV1Transport(origin: metadata == nil ? config.bootstrapEndpoint : config.serverEndpoint,
                hostname: config.serverHostname, trustedCAPEM: ca, identity: metadata.map { try store.identity(for: $0) })
        }
        reload()
        wantsConnection = automaticallyConnect && credential != nil && state == .disconnected
    }

    var displayedState: ConnectionState {
        if state == .connected, lease?.valid() != true || (credential?.expiresAt ?? .distantPast) <= Date() { return .reconnecting }
        return state
    }
    var canProvision: Bool { credential == nil && configuration != nil && trustedCAAvailable && !busy }
    var busy: Bool { [.provisioning, .discovering, .authenticating, .registering].contains(state) }

    func signIn(email: String, apiKey: String, gateway: (any SoftwareLoginGateway)? = nil) async {
        guard purpose == .caller, credential == nil, !busy, !signingIn else { return }
        stopTasks()
        let token = generation
        signingIn = true
        provisioning = .notProvisioned
        transition(.provisioning)
        defer { signingIn = false }
        do {
            let login = try gateway ?? URLSessionSoftwareLogin(profile: LoginProfile.bundled())
            let bootstrap = try await login.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: apiKey)
            guard token == generation, foreground else { return }
            try store.storeConfiguration(bootstrap.configuration)
            try store.storeTrustedCA(bootstrap.caPEM)
            configuration = bootstrap.configuration
            trustedCAAvailable = true
            transition(.unconfigured)
            await provision(invitationData: bootstrap.invitationData)
        } catch {
            guard token == generation else { return }
            let error = failure(error)
            provisioning = .failed(error)
            transition(.failed(error))
        }
    }

    func conversationAccess() throws -> ConversationAccess {
        guard purpose == .caller, displayedState == .connected, let credential, credential.purpose == .caller, let session else { throw ChatFailure.notConnected }
        return ConversationAccess(clientID: credential.clientID, sessionID: session.sessionID,
            origin: credential.configuration.serverEndpoint,
            transport: try URLSessionConversationTransport(configuration: credential.configuration,
                caPEM: credential.trustedCAPEM, identity: store.identity(for: credential)))
    }

    private func reload() {
        do {
            credential = try store.load()
            if let credential, credential.purpose != purpose { throw ClientFailure.invalidCertificate }
            if let stored = credential, let profile = try? LoginProfile.bundled(),
               let migrated = try? stored.migratedForLAN(profile: profile) {
                try store.save(migrated)
                credential = migrated
            }
            configuration = try credential?.configuration ?? store.configuration() ?? ClientConfiguration.bundled()
            trustedCAAvailable = try credential != nil || store.trustedCA() != nil
            if let credential {
                try credential.validate()
                try store.validateStoredIdentity(credential)
                provisioning = .provisioned
                state = .disconnected
            } else { provisioning = .notProvisioned; state = .unconfigured }
        } catch {
            provisioning = .failed(failure(error))
            state = .failed(failure(error))
        }
    }

    func importConfiguration(_ data: Data) throws {
        guard credential == nil, !busy else { throw ClientFailure.configuration }
        let config = try ClientConfiguration.parse(data)
        try store.storeConfiguration(config)
        configuration = config
        discovery = .unknown
        state = .unconfigured
        provisioning = .notProvisioned
    }
    func importCA(_ data: Data) throws {
        guard credential == nil, !busy, let pem = String(data: data, encoding: .utf8) else { throw ClientFailure.invalidCertificate }
        try store.storeTrustedCA(pem)
        trustedCAAvailable = true
        discovery = .unknown
        state = .unconfigured
        provisioning = .notProvisioned
    }

    func discover() async {
        guard !busy, let config = configuration else { state = .failed(.configuration); return }
        stopTasks()
        let token = generation
        do {
            let ca = try trustedCA()
            transition(.discovering)
            discovery = .discovering
            let transport = try factory(config, ca, nil)
            _ = try V1Discovery(await transport.send(path: "/client-interface/v1/discovery", body: nil))
            guard token == generation else { return }
            discovery = .compatible
            transition(credential == nil ? .unconfigured : .disconnected)
        } catch {
            guard token == generation else { return }
            let failure = failure(error)
            discovery = failure == .unsupportedProtocol ? .incompatible : .failed
            transition(.failed(failure))
        }
    }

    func provision(invitationData: Data, connectAfterProvisioning: Bool = true) async {
        guard canProvision, let config = configuration else { return }
        stopTasks()
        let token = generation
        transition(.provisioning)
        do {
            let invitation = try ProvisioningInvitation(data: invitationData, configuration: config, purpose: purpose)
            provisioning = .invitationSelected
            let ca = try trustedCA()
            let transport = try factory(config, ca, nil)
            discovery = .discovering
            _ = try V1Discovery(await transport.send(path: "/client-interface/v1/discovery", body: nil))
            guard token == generation, foreground else { return }
            discovery = .compatible
            let pending = try store.prepare(invitation: invitation, configuration: config, caPEM: ca, progress: { phase in
                self.provisioning = phase
                self.logger.info("V1 provisioning: \(phase.label, privacy: .public)")
            })
            provisioning = .enrolling
            let response = try await transport.send(path: "/client-interface/v1/enroll", body: .object([
                "invitation_id": .string(invitation.invitationID), "token": .string(invitation.token), "csr_pem": .string(pending.csrPEM)
            ]))
            // The private key stays on the device. The invitation/token are never persisted.
            guard token == generation, foreground else { return }
            let bundle = try EnrollmentBundle(response, configuration: config, embodimentID: invitation.embodimentID, visionObserveGranted: invitation.visionObserveGranted)
            let issued = try store.finish(bundle: bundle, pending: pending)
            guard issued.purpose == purpose, issued.embodimentID == invitation.embodimentID, (issued.visionObserveGranted == true) == invitation.visionObserveGranted else { throw ClientFailure.invalidCertificate }
            credential = issued
            provisioning = .provisioned
            transition(.disconnected)
            if connectAfterProvisioning { connect() }
        } catch {
            guard token == generation else { return }
            let failure = failure(error)
            provisioning = .failed(failure)
            if discovery == .discovering { discovery = failure == .unsupportedProtocol ? .incompatible : .failed }
            transition(.failed(failure))
        }
    }

    func embodimentSetupAccess() throws -> (EmbodimentSetupTransport, String, CredentialMetadata) {
        guard purpose == .caller, displayedState == .connected, let credential, let session else { throw ChatFailure.notConnected }
        return (try EmbodimentSetupTransport(configuration: credential.configuration, ca: credential.trustedCAPEM,
                    identity: store.identity(for: credential)), session.sessionID, credential)
    }
    func updateDeviceCameraGrant(_ enabled: Bool) throws {
        guard purpose == .device, var metadata = credential else { throw ClientFailure.invalidCertificate }
        metadata.visionObserveGranted = enabled
        try store.save(metadata)
        credential = metadata
    }

    func deviceTransport() throws -> any V1Transport {
        guard purpose == .device, displayedState == .connected, let credential, credential.purpose == .device else { throw ClientFailure.authenticationRequired }
        return try factory(credential.configuration, credential.trustedCAPEM, credential)
    }

    func inspectionTransport(requireCamera: Bool = true) throws -> any InspectionTransport {
        guard purpose == .device, displayedState == .connected, let credential,
              let sessionID = session?.sessionID, credential.purpose == .device,
              (!requireCamera || credential.visionObserveGranted == true) else { throw ClientFailure.authenticationRequired }
        let key = credential.clientID + "\n" + sessionID
        if let channel = inspectionChannel, channel.0 == key { return channel.1 }
        let channel = try URLSessionInspectionTransport(configuration: credential.configuration,
            ca: credential.trustedCAPEM, identity: store.identity(for: credential))
        inspectionChannel = (key, channel)
        return channel
    }

    func connect() {
        guard foreground, let credential else { return }
        do { try credential.validate() }
        catch { wantsConnection = false; stopTasks(); transition(.failed(failure(error))); return }
        stopTasks()
        wantsConnection = true
        let token = generation
        worker = Task { [weak self] in await self?.run(token: token) }
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.state == .connected, self.lease?.valid() != true || (self.credential?.expiresAt ?? .distantPast) <= Date() {
                    self.lease = nil
                    self.session = nil
                    self.transition(.reconnecting)
                }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    private func run(token: Int) async {
        var pendingRegistration: V1Request?
        var retryDelay: TimeInterval = 1
        while token == generation, !Task.isCancelled, foreground, wantsConnection, let credential {
            do {
                try credential.validate()
                let config = credential.configuration
                let ca = credential.trustedCAPEM
                transition(.discovering)
                discovery = .discovering
                let bootstrap = try factory(config, ca, nil)
                maxMediaBytes = try V1Discovery(await bootstrap.send(path: "/client-interface/v1/discovery", body: nil)).maxMediaBytes
                guard token == generation, !Task.isCancelled else { return }
                discovery = .compatible
                transition(.authenticating)
                let client = try factory(config, ca, credential)
                _ = try V1Discovery(await client.send(path: "/client-interface/v1/discovery", body: nil))
                guard token == generation, !Task.isCancelled else { return }
                transition(.registering)
                if pendingRegistration == nil || pendingRegistration!.deadline <= Date() {
                    pendingRegistration = V1Request(operation: "session.register", clientID: credential.clientID, version: AppMetadata().version, embodimentID: credential.embodimentID, manifest: manifestProvider())
                }
                var registeredManifest = pendingRegistration!.value
                if case .object(let r) = registeredManifest, case .object(let a) = r["arguments"], let m = a["manifest"] { registeredManifest = m }
                var active = try await control(pendingRegistration!, client: client, credential: credential, token: token)
                pendingRegistration = nil
                retryDelay = 1
                while token == generation, !Task.isCancelled {
                    guard let lease, lease.valid() else { throw ClientFailure.remote(try staleError()) }
                    try await Task.sleep(for: .seconds(max(0.05, lease.heartbeatDelay)))
                    guard token == generation, !Task.isCancelled, self.lease?.valid() == true else { throw ClientFailure.remote(try staleError()) }
                    try credential.validate()
                    var updatedManifest = manifestProvider()
                    if case .object(var fields) = updatedManifest { fields["revision"] = .integer(active.manifestRevision); updatedManifest = .object(fields) }
                    if purpose == .device && updatedManifest != registeredManifest {
                        if case .object(var fields) = updatedManifest { fields["revision"] = .integer(active.manifestRevision + 1); updatedManifest = .object(fields) }
                        active = try await control(V1Request(operation: "session.capabilities", sessionID: active.sessionID, clientID: credential.clientID, version: AppMetadata().version, embodimentID: credential.embodimentID, manifest: updatedManifest), client: client, credential: credential, token: token)
                        registeredManifest = updatedManifest
                    }
                    active = try await control(V1Request(operation: "session.heartbeat", sessionID: active.sessionID,
                        clientID: credential.clientID, version: AppMetadata().version, embodimentID: credential.embodimentID), client: client, credential: credential, token: token)
                }
            } catch {
                guard token == generation, !Task.isCancelled else { return }
                let failure = failure(error)
                session = nil; lease = nil
                if discovery == .discovering { discovery = failure == .unsupportedProtocol ? .incompatible : .failed }
                if failure.requiresProvisioning {
                    var rejected = credential
                    rejected.authenticationRejected = true
                    do { try store.save(rejected); self.credential = rejected }
                    catch { wantsConnection = false; stopTasks(); transition(.failed(self.failure(error))); return }
                }
                if !failure.retryable { wantsConnection = false; stopTasks(); transition(.failed(failure)); return }
                transition(.reconnecting)
                var delay = retryDelay
                if case .remote(let error) = failure, let ms = error.retryAfterMS { delay = max(delay, min(60, Double(ms) / 1000)) }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                retryDelay = min(30, retryDelay * 2)
            }
        }
    }

    private func control(_ request: V1Request, client: any V1Transport, credential: CredentialMetadata, token: Int) async throws -> SessionView {
        let clock = ContinuousClock()
        let started = clock.now
        let response = try await client.send(path: "/client-interface/v1/messages", body: request.value)
        guard token == generation, !Task.isCancelled else { throw CancellationError() }
        try credential.validate()
        let view = try SessionView(V1Response(response, request: request).result)
        var expectedRevision = session?.manifestRevision ?? 1
        if case .object(let r) = request.value, case .object(let a) = r["arguments"], case .object(let m) = a["manifest"], case .integer(let revision) = m["revision"] { expectedRevision = revision }
        try view.validatePrincipal(credential.clientID, embodimentID: credential.embodimentID, request: request,
            allowedCapabilities: purpose == .device && credential.visionObserveGranted == true ? ["vision.observe"] : [], expectedRevision: expectedRevision)
        if view.state == .replaced { throw ClientFailure.replaced }
        guard view.state == .active else { throw ClientFailure.remote(try staleError()) }
        let duration = started.duration(to: clock.now).components
        let roundTrip = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        let lease = SessionLease(view: view, roundTrip: roundTrip)
        guard lease.valid() else { throw ClientFailure.remote(try staleError()) }
        session = view; self.lease = lease
        transition(.connected)
        logger.debug("V1 ACTIVE lease accepted")
        return view
    }

    func disconnect() async {
        let oldSession = session
        let oldCredential = credential
        wantsConnection = false
        stopTasks()
        transition(restingState())
        guard let oldSession, let oldCredential else { return }
        do {
            let transport = try factory(oldCredential.configuration, oldCredential.trustedCAPEM, oldCredential)
            await sendDisconnect(oldSession, credential: oldCredential, transport: transport)
        } catch { logger.debug("V1 disconnect could not be acknowledged; local authority cleared") }
    }

    private func sendDisconnect(_ session: SessionView, credential: CredentialMetadata, transport: any V1Transport) async {
        do {
            let request = V1Request(operation: "session.disconnect", sessionID: session.sessionID, clientID: credential.clientID, version: AppMetadata().version, embodimentID: credential.embodimentID)
            _ = try V1Response(await transport.send(path: "/client-interface/v1/messages", body: request.value), request: request)
        } catch { logger.debug("V1 disconnect could not be acknowledged; local authority cleared") }
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if active {
            if credential == nil || !wantsConnection { return }
            connect()
        } else {
            stopTasks() // iOS may suspend: do not retain a Connected label or pretend to maintain heartbeats.
            if credential == nil { provisioning = .notProvisioned }
            if case .failed = state { return }
            transition(restingState())
        }
    }
    func forgetCredential() async {
        let oldSession = session
        let oldCredential = credential
        // Capture only the scoped disconnect transport before erasing the key.
        // All local teardown happens before awaiting I/O, so a concurrent Connect
        // cannot resurrect the credential that the user is removing.
        let transport: (any V1Transport)?
        if oldSession != nil, let oldCredential {
            transport = try? factory(oldCredential.configuration, oldCredential.trustedCAPEM, oldCredential)
        } else { transport = nil }
        wantsConnection = false
        stopTasks()
        do { try store.forget(); reload() }
        catch { transition(.failed(failure(error))); return }
        if let oldSession, let oldCredential, let transport {
            await sendDisconnect(oldSession, credential: oldCredential, transport: transport)
        }
    }
    func reportImportError(_ error: any Error) { transition(.failed(failure(error))) }

    private func trustedCA() throws -> String {
        guard let ca = try credential?.trustedCAPEM ?? store.trustedCA() else { throw ClientFailure.trustRequired }
        return ca
    }
    private func restingState() -> ConnectionState {
        guard let credential else { return .unconfigured }
        if credential.authenticationRejected { return .failed(.authenticationRequired) }
        if credential.expiresAt <= Date() { return .failed(.credentialExpired) }
        return .disconnected
    }
    private func stopTasks() {
        generation += 1
        worker?.cancel(); worker = nil
        watchdog?.cancel(); watchdog = nil
        session = nil; lease = nil
    }
    private func transition(_ newState: ConnectionState) {
        state = newState
        logger.info("V1 state: \(newState.label, privacy: .public)")
    }
    private func failure(_ error: any Error) -> ClientFailure { error as? ClientFailure ?? .invalidResponse }
    private func staleError() throws -> V1Error {
        try V1Error(.object(["code": .string("CONFLICT"), "detail_code": .string("stale_session"), "message": .string("Lease is not active."), "retryable": .bool(true), "retry_after_ms": .null]))
    }
}
