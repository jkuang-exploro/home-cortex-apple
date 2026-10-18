import SwiftUI

struct ConversationView: View {
    @Bindable var connection: ConnectionController
    @State private var chat: ConversationController
    let embodiment: EmbodimentController
    @State private var showConnection = false
    @State private var showEmbodiment = false
    init(connection: ConnectionController, chat: ConversationController, embodiment: EmbodimentController) {
        self.embodiment = embodiment
        self.connection = connection
        _chat = State(initialValue: chat)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ConversationConnectionStatus(connection: connection, chat: chat)
                Menu {
                    Button("None") { chat.selectEmbodiment(nil) }
                    if let id = embodiment.embodimentID {
                        Button("This iPhone") {
                            Task { if embodiment.vision.configured { await embodiment.vision.requestPermission() }; chat.selectEmbodiment(id) }
                        }
                    }
                } label: {
                    Text("Using embodiment: " + (chat.activeEmbodimentID == nil ? "None" : chat.activeEmbodimentID == embodiment.embodimentID ? "This iPhone" : "Another embodiment"))
                }.disabled(chat.state != .ready).accessibilityIdentifier("chat.embodiment").padding(.bottom, 8)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(chat.messages) { message in
                                ConversationMessageRow(message: message, canRetry: chat.state == .ready) { chat.retry(message.id) }
                                    .id(message.id)
                            }
                            Color.clear.frame(height: 1).id("latest")
                        }.padding()
                    }
                    .onChange(of: chat.messageRevision) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
                }
                if chat.state == .loading { ProgressView("Loading conversation…").padding(8) }
                if case .failed(let failure) = chat.state {
                    VStack(spacing: 6) {
                        Text(failure.localizedDescription).font(.callout)
                        Button("Reload history") { chat.load() }.disabled(connection.displayedState != .connected)
                    }.padding(10).accessibilityIdentifier("chat.error")
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .safeAreaInset(edge: .bottom) {
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("请输入消息… / Message…", text: $chat.draft, axis: .vertical)
                        .lineLimit(1...6).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("chat.input")
                    if chat.state == .sending {
                        Button("Stop", systemImage: "stop.fill") { chat.stop() }
                            .accessibilityIdentifier("chat.stop")
                    } else {
                        Button("Send", systemImage: "arrow.up") { chat.send() }
                            .labelStyle(.iconOnly).buttonStyle(.borderedProminent)
                            .disabled(!chat.canSend).accessibilityIdentifier("chat.send")
                    }
                }.padding().frame(maxWidth: 760).frame(maxWidth: .infinity).background(.bar)
            }
            .navigationTitle("Home Cortex").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Embodiment", systemImage: "iphone") { showEmbodiment = true }
                    .accessibilityIdentifier("chat.manage-embodiment")
                Button("Connection", systemImage: "gearshape") { showConnection = true }
            }
            .sheet(isPresented: $showEmbodiment) {
                NavigationStack {
                    ScrollView { EmbodimentView(embodiment: embodiment, caller: connection) }
                        .toolbar { Button("Done") { showEmbodiment = false } }
                }
            }
            .sheet(isPresented: $showConnection) {
                NavigationStack {
                    ConnectionView(connection: connection, embodiment: embodiment)
                        .toolbar { Button("Done") { showConnection = false } }
                }
            }
        }
        .onDisappear { chat.stop() }
    }
}

private struct ConversationConnectionStatus: View {
    let connection: ConnectionController
    let chat: ConversationController
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack {
                Text("老管家").font(.title2.bold())
                Spacer()
                Label(connection.displayedState.label, systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(connection.displayedState == .connected ? Color.green : Color.secondary)
                    .accessibilityIdentifier("chat.connection")
            }.padding()
            .task { chat.connectionChanged(connected: connection.displayedState == .connected) }
            .onChange(of: connection.displayedState) { _, state in chat.connectionChanged(connected: state == .connected) }
        }
    }
}

private struct ConversationMessageRow: View {
    let message: ChatMessage
    let canRetry: Bool
    let retry: () -> Void
    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: 6) {
                Text(message.role == .assistant ? "老管家" : "我 / Me")
                    .font(.caption).foregroundStyle(.secondary)
                if message.content.isEmpty && message.state == .receiving { ProgressView() }
                else { Text(message.content).textSelection(.enabled) }
                if case .pending = message.state { Text("Sending…").font(.caption).foregroundStyle(.secondary) }
                if case .failed(let failure, let safe) = message.state {
                    Text(failure.localizedDescription).font(.caption).foregroundStyle(.red)
                    if safe { Button("Retry") { retry() }.disabled(!canRetry) }
                }
            }
            .padding(14)
            .background(message.role == .user ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16))
            if message.role == .assistant { Spacer(minLength: 44) }
        }
    }
}
