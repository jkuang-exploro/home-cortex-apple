import Foundation
import Observation

enum ConversationState: Equatable {
    case idle, loading, ready, sending
    case failed(ChatFailure)
}

@MainActor @Observable
final class ConversationController {
    private(set) var state: ConversationState = .idle
    private(set) var messages: [ChatMessage] = [] { didSet { messageRevision &+= 1 } }
    private(set) var messageRevision = 0
    private(set) var activeEmbodimentID: String?
    private(set) var conversationID: String?
    var draft = ""
    @ObservationIgnored private let access: @MainActor () throws -> ConversationAccess
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let isConnected: @MainActor () -> Bool
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ownerKey: String?
    @ObservationIgnored private var activeTurn: ActiveTurn?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    private struct ActiveTurn {
        let userIndex: Int
        let assistantIndex: Int
        let userID: String
        let assistantID: String
        var byteCount = 0
        var pendingText = ""
    }

    init(defaults: UserDefaults = .standard, isConnected: @escaping @MainActor () -> Bool = { true },
         access: @escaping @MainActor () throws -> ConversationAccess) {
        self.defaults = defaults
        self.access = access
        self.isConnected = isConnected
    }
    var canSend: Bool {
        state == .ready && conversationID != nil && isConnected()
        && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.unicodeScalars.count <= 32_000
    }
    func connectionChanged(connected: Bool) {
        if !connected {
            if state == .sending { stop() }
            else if state == .loading {
                generation += 1; task?.cancel(); task = nil; state = .idle
            }
        } else if state != .sending && state != .loading { load() }
    }
    func load() {
        guard state != .sending, state != .loading else { return }
        let context: ConversationAccess
        do { context = try access() }
        catch { state = .failed(ChatFailure.map(error)); return }
        activeTurn = nil
        generation += 1
        let token = generation
        if ownerKey != context.selectionKey {
            messages = []; conversationID = nil; activeEmbodimentID = nil; ownerKey = context.selectionKey
        }
        state = .loading
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let document: ConversationDocument
                if let id = conversationID ?? defaults.string(forKey: context.selectionKey) {
                    do { document = try await context.transport.history(id: id, sessionID: context.sessionID) }
                    catch ChatFailure.notFound { document = try await context.transport.selectOrCreate(sessionID: context.sessionID) }
                } else { document = try await context.transport.selectOrCreate(sessionID: context.sessionID) }
                try Task.checkCancellation()
                guard token == generation else { return }
                activeEmbodimentID = document.active_embodiment_id
                conversationID = document.id
                defaults.set(document.id, forKey: context.selectionKey)
                let unsent = messages.filter {
                    if case .failed(_, safeToRetry: true) = $0.state { return true }
                    return false
                }
                messages = document.history + unsent
                state = .ready
            } catch {
                guard token == generation else { return }
                state = .failed(ChatFailure.map(error))
            }
            if token == generation { task = nil }
        }
    }
    func selectEmbodiment(_ body: String?) {
        guard state == .ready, let id = conversationID else { return }
        let context: ConversationAccess
        do { context = try access() } catch { state = .failed(ChatFailure.map(error)); return }
        activeTurn = nil
        generation += 1
        let token = generation
        state = .loading
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let document = try await context.transport.setActive(id: id, embodimentID: body, sessionID: context.sessionID)
                try Task.checkCancellation()
                guard token == generation, document.id == id, document.active_embodiment_id == body else { throw ChatFailure.invalidResponse }
                activeEmbodimentID = document.active_embodiment_id
                state = .ready
            } catch {
                if token == generation { state = .failed(ChatFailure.map(error)) }
            }
            if token == generation { task = nil }
        }
    }
    func send() {
        let content = draft // Preserve the original bilingual text, including whitespace.
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, content.unicodeScalars.count <= 32_000,
              state != .sending, state != .loading else { return }
        let userID = UUID().uuidString
        let context: ConversationAccess
        do {
            context = try access()
            guard state == .ready, conversationID != nil else { throw ChatFailure.notConnected }
        } catch {
            messages.append(ChatMessage(id: userID, role: .user, content: content,
                state: .failed(ChatFailure.map(error), safeToRetry: true)))
            draft = ""
            return
        }
        guard let id = conversationID else { return }
        activeTurn = nil
        generation += 1
        let token = generation
        let assistantID = UUID().uuidString
        messages.append(ChatMessage(id: userID, role: .user, content: content, state: .pending))
        messages.append(ChatMessage(id: assistantID, role: .assistant, content: "", state: .receiving))
        activeTurn = ActiveTurn(userIndex: messages.count - 2, assistantIndex: messages.count - 1,
            userID: userID, assistantID: assistantID)
        draft = ""
        state = .sending
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await context.transport.stream(id: id, content: content, sessionID: context.sessionID) { [weak self] event in
                    try await self?.receive(event, token: token, userID: userID, assistantID: assistantID)
                }
                try Task.checkCancellation()
                guard token == generation else { return }
                guard messages.last?.state == .complete else { throw ChatFailure.invalidResponse }
                state = .ready
            } catch {
                guard token == generation else { return }
                failTurn(ChatFailure.map(error), userID: userID, assistantID: assistantID)
            }
            if token == generation { task = nil }
        }
    }
    private func receive(_ event: ConversationEvent, token: Int, userID: String, assistantID: String) throws {
        guard token == generation else { throw CancellationError() }
        guard let user = activeTurn?.userIndex, let assistant = activeTurn?.assistantIndex,
              activeTurn?.userID == userID, activeTurn?.assistantID == assistantID,
              messages.indices.contains(user), messages.indices.contains(assistant),
              messages[user].id == userID, messages[assistant].id == assistantID else { throw ChatFailure.invalidResponse }
        if messages[user].state != .sent { messages[user].state = .sent }
        switch event {
        case .delta(let text):
            let count = text.utf8.count
            guard count <= 1_048_576 - (activeTurn?.byteCount ?? 0) else { throw ChatFailure.invalidResponse }
            activeTurn?.byteCount += count
            activeTurn?.pendingText.append(contentsOf: text)
            if flushTask == nil {
                flushTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                    guard let self, token == generation else { return }
                    flushPendingText()
                }
            }
        case .complete:
            guard (activeTurn?.byteCount ?? 0) > 0 else { throw ChatFailure.invalidResponse }
            flushPendingText()
            messages[assistant].state = .complete
            activeTurn = nil
        }
    }
    private func flushPendingText() {
        flushTask?.cancel(); flushTask = nil
        guard var turn = activeTurn, !turn.pendingText.isEmpty,
              messages.indices.contains(turn.assistantIndex), messages[turn.assistantIndex].id == turn.assistantID else { return }
        messages[turn.assistantIndex].content += turn.pendingText
        turn.pendingText = ""
        activeTurn = turn
    }
    private func failTurn(_ failure: ChatFailure, userID: String, assistantID: String) {
        flushPendingText()
        if let turn = activeTurn {
            for index in [turn.userIndex, turn.assistantIndex] where messages.indices.contains(index) {
                messages[index].state = .failed(failure, safeToRetry: false)
            }
        } else {
            for index in messages.indices where messages[index].id == userID || messages[index].id == assistantID {
                messages[index].state = .failed(failure, safeToRetry: false)
            }
        }
        activeTurn = nil
        state = .failed(failure)
    }
    func stop() {
        guard state == .sending else { return }
        generation += 1
        task?.cancel(); task = nil
        if let assistant = messages.last, let user = messages.dropLast().last {
            failTurn(.interrupted, userID: user.id, assistantID: assistant.id)
        }
    }
    func retry(_ id: String) {
        guard state == .ready, let index = messages.firstIndex(where: { $0.id == id }),
              case .failed(_, safeToRetry: true) = messages[index].state else { return }
        draft = messages.remove(at: index).content
        send()
    }
}
