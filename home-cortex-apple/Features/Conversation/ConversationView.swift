import SwiftUI

struct ConversationView: View {
    @Bindable var connection: ConnectionController
    @State private var chat: ConversationController
    @State private var showConnection = false
    init(connection: ConnectionController, chat: ConversationController) {
        self.connection = connection
        _chat = State(initialValue: chat)
    }
    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(spacing: 0) {
                    HStack {
                        Text("老管家").font(.title2.bold())
                        Spacer()
                        Label(connection.displayedState.label, systemImage: "circle.fill")
                            .font(.caption)
                            .foregroundStyle(connection.displayedState == .connected ? Color.green : Color.secondary)
                            .accessibilityIdentifier("chat.connection")
                    }.padding()
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 20) {
                                ForEach(chat.messages) { message in
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
                                                if safe { Button("Retry") { chat.retry(message.id) }.disabled(chat.state != .ready) }
                                            }
                                        }
                                        .padding(14)
                                        .background(message.role == .user ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground),
                                                    in: RoundedRectangle(cornerRadius: 16))
                                        if message.role == .assistant { Spacer(minLength: 44) }
                                    }.id(message.id)
                                }
                                Color.clear.frame(height: 1).id("latest")
                            }.padding()
                        }
                        .onChange(of: chat.messages) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
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
                .task { chat.connectionChanged(connected: connection.displayedState == .connected) }
                .onChange(of: connection.displayedState) { _, state in chat.connectionChanged(connected: state == .connected) }
            }
            .navigationTitle("Home Cortex").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Connection", systemImage: "gearshape") { showConnection = true } }
            .sheet(isPresented: $showConnection) {
                NavigationStack {
                    ConnectionView(connection: connection)
                        .toolbar { Button("Done") { showConnection = false } }
                }
            }
        }
        .onDisappear { chat.stop() }
    }
}
