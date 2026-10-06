import SwiftUI

@MainActor
enum AppRuntime {
    static let connection = ConnectionController()
    static let chat = ConversationController(isConnected: { connection.displayedState == .connected }) {
        try connection.conversationAccess()
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var connection: ConnectionController

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-unprovisioned") {
            let store = KeychainCredentialStore(service: "HomeCortex.UITests.Unprovisioned")
            try? store.forget()
            _connection = State(initialValue: ConnectionController(store: store))
            return
        }
        #endif
        _connection = State(initialValue: AppRuntime.connection)
    }

    var body: some View {
        Group {
            if connection.credential != nil { ConversationView(connection: connection, chat: AppRuntime.chat) }
            else { ConnectionView(connection: connection) }
        }
            .task { connection.setForeground(scenePhase == .active) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { connection.setForeground(true) }
                else if phase == .background { connection.setForeground(false) }
            }
    }
}
