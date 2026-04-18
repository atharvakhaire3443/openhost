import Foundation
import Combine

@MainActor
final class ChatSession: ObservableObject {
    static let shared = ChatSession()

    @Published private(set) var isStreaming: Bool = false
    @Published private(set) var liveTokensPerSecond: Double = 0
    @Published private(set) var liveCompletionChars: Int = 0
    @Published private(set) var liveTTFTms: Int?
    @Published private(set) var lastError: String?

    private var task: Task<Void, Never>?
    private var streamStart: Date?
    private var firstTokenAt: Date?

    private init() {}

    func send(userText: String, attachments: [MessageAttachment] = [], webSearch: Bool = false, in conversationID: UUID) {
        guard !isStreaming else { return }
        let registry = ModelRegistry.shared
        let store = ChatStore.shared

        guard let runtime = registry.activeRuntime, runtime.state == .running, runtime.isReachable else {
            lastError = "No running model. Start one in the Models tab."
            return
        }

        guard store.binding(for: conversationID) != nil else { return }

        Task { [weak self] in
            guard let self else { return }
            var finalText = userText
            if webSearch, !userText.isEmpty {
                let settings = AppSettings.shared
                let provider = SearchRouter.makeProvider(from: settings)
                do {
                    let results = try await provider.search(query: userText, maxResults: settings.searchMaxResults)
                    let formatted = SearchResult.format(results, for: userText)
                    finalText = formatted + "Question: " + userText + "\n\nUse the search results above to ground your answer. Cite URLs inline."
                } catch {
                    finalText = "[Web search failed: \(error.localizedDescription)]\n\n" + userText
                }
            }
            await self.performSend(finalText: finalText, originalText: userText, attachments: attachments, conversationID: conversationID, runtime: runtime)
        }
    }

    private func performSend(finalText: String, originalText: String, attachments: [MessageAttachment], conversationID: UUID, runtime: ModelRuntime) async {
        let store = ChatStore.shared
        let userMsg = Message(role: .user, content: originalText, attachments: attachments)
        store.appendMessage(userMsg, to: conversationID)

        var assistant = Message(role: .assistant, content: "", stats: MessageStats(backend: runtime.definition.backend.rawValue))
        store.appendMessage(assistant, to: conversationID)

        guard var convo = store.binding(for: conversationID) else { return }
        if !convo.messages.isEmpty, let lastUserIdx = convo.messages.lastIndex(where: { $0.role == .user }) {
            convo.messages[lastUserIdx].content = finalText
        }

        let client = ChatClient(port: runtime.definition.port, apiModelName: runtime.effectiveApiModelName)
        let settings = convo.settings
        let historyForAPI = convo.messages.dropLast().filter { $0.role != .system || !$0.content.isEmpty }

        lastError = nil
        isStreaming = true
        streamStart = Date()
        firstTokenAt = nil
        liveTokensPerSecond = 0
        liveCompletionChars = 0
        liveTTFTms = nil

        task = Task { [weak self] in
            guard let self else { return }
            var accumulated = ""
            var finalUsage: UsageInfo?

            do {
                for try await event in client.stream(messages: Array(historyForAPI), settings: settings) {
                    if let delta = event.deltaText {
                        if self.firstTokenAt == nil {
                            self.firstTokenAt = Date()
                            if let s = self.streamStart {
                                self.liveTTFTms = Int(Date().timeIntervalSince(s) * 1000)
                            }
                        }
                        accumulated += delta
                        self.liveCompletionChars = accumulated.count
                        assistant.content = accumulated
                        ChatStore.shared.updateLastAssistantMessage(in: conversationID) { msg in
                            msg.content = accumulated
                        }
                        if let first = self.firstTokenAt {
                            let elapsed = Date().timeIntervalSince(first)
                            if elapsed > 0.05 {
                                let approxTokens = Double(accumulated.count) / 4.0
                                self.liveTokensPerSecond = approxTokens / elapsed
                            }
                        }
                    }
                    if let u = event.usage { finalUsage = u }
                    if event.finished { break }
                }
            } catch is CancellationError {
                ChatStore.shared.updateLastAssistantMessage(in: conversationID) { msg in
                    if msg.content.isEmpty { msg.content = "_[cancelled]_" }
                }
            } catch {
                self.lastError = error.localizedDescription
                ChatStore.shared.updateLastAssistantMessage(in: conversationID) { msg in
                    if msg.content.isEmpty { msg.content = "_Error: \(error.localizedDescription)_" }
                }
            }

            let elapsedMs = Int(Date().timeIntervalSince(self.streamStart ?? Date()) * 1000)
            let completionTokens = finalUsage?.completionTokens ?? max(1, accumulated.count / 4)
            let timeSinceFirst = self.firstTokenAt.map { Date().timeIntervalSince($0) } ?? 0.001
            let tokPerSec = timeSinceFirst > 0 ? Double(completionTokens) / timeSinceFirst : 0

            ChatStore.shared.updateLastAssistantMessage(in: conversationID) { msg in
                msg.stats = MessageStats(
                    ttftMs: self.liveTTFTms,
                    tokensPerSecond: tokPerSec,
                    completionTokens: completionTokens,
                    promptTokens: finalUsage?.promptTokens,
                    totalTokens: finalUsage?.totalTokens,
                    backend: runtime.definition.backend.rawValue,
                    elapsedMs: elapsedMs
                )
            }
            if let convo = ChatStore.shared.binding(for: conversationID) {
                ChatStore.shared.update(convo)
            }

            self.isStreaming = false
            self.task = nil
        }
    }

    func stop() {
        task?.cancel()
        isStreaming = false
    }

    func regenerate(in conversationID: UUID) {
        guard !isStreaming else { return }
        let store = ChatStore.shared
        store.removeLastAssistantMessage(in: conversationID)
        guard let lastUser = store.binding(for: conversationID)?.messages.last, lastUser.role == .user else { return }
        let text = lastUser.content
        store.popLastMessage(in: conversationID)
        send(userText: text, in: conversationID)
    }
}
