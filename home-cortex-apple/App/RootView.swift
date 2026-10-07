import SwiftUI

@MainActor
enum AppRuntime {
    static let connection = ConnectionController()
    static let embodiment = EmbodimentController()
    static let chat = ConversationController(isConnected: { connection.displayedState == .connected }) {
        try connection.conversationAccess()
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var connection: ConnectionController
    @State private var embodiment: EmbodimentController

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-unprovisioned") {
            let store = KeychainCredentialStore(service: "HomeCortex.UITests.Unprovisioned")
            try? store.forget()
            _connection = State(initialValue: ConnectionController(store: store))
            let deviceStore = KeychainCredentialStore(service: "HomeCortex.UITests.Unprovisioned", purpose: .device)
            try? deviceStore.forget()
            try? deviceStore.storeRuntimeEnabled(false)
            _embodiment = State(initialValue: EmbodimentController(store: deviceStore))
            return
        }
        #endif
        _connection = State(initialValue: AppRuntime.connection)
        _embodiment = State(initialValue: AppRuntime.embodiment)
    }

    var body: some View {
        Group {
            if connection.credential != nil { ConversationView(connection: connection, chat: AppRuntime.chat, embodiment: embodiment) }
            else { LoginView(connection: connection, embodiment: embodiment) }
        }
            .task {
                connection.setForeground(scenePhase == .active)
                embodiment.setForeground(scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { connection.setForeground(true); embodiment.setForeground(true) }
                else if phase == .background { connection.setForeground(false); embodiment.setForeground(false) }
            }
    }
}
