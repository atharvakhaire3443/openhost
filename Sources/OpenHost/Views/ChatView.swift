import SwiftUI

struct ChatView: View {
    @EnvironmentObject var registry: ModelRegistry
    @StateObject private var store = ChatStore.shared
    @StateObject private var session = ChatSession.shared
    @State private var showSettings: Bool = true

    var body: some View {
        HSplitView {
            ConversationListView(store: store)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

            VStack(spacing: 0) {
                ChatStatsBar(
                    registry: registry,
                    session: session,
                    conversation: store.selected
                )
                Divider()
                if let convo = store.selected {
                    ConversationPane(conversation: convo)
                        .id(convo.id)
                } else {
                    Text("No conversation selected").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 480)

            if showSettings, let convo = store.selected {
                ChatSettingsView(conversationID: convo.id)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Export as Markdown") {
                        if let c = store.selected { ChatExporter.export(c, format: .markdown) }
                    }
                    Button("Export as JSON") {
                        if let c = store.selected { ChatExporter.export(c, format: .json) }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Export chat")
                .disabled(store.selected == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showSettings.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("Toggle settings")
            }
        }
    }
}

struct ConversationPane: View {
    let conversation: Conversation
    @EnvironmentObject var registry: ModelRegistry
    @StateObject private var session = ChatSession.shared
    @StateObject private var store = ChatStore.shared
    @State private var composerText: String = ""
    @State private var pendingAttachments: [MessageAttachment] = []
    @State private var attachmentError: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(conversation.messages) { msg in
                            MessageBubbleView(message: msg)
                                .id(msg.id)
                        }
                        if let err = session.lastError {
                            Text(err)
                                .font(.caption).foregroundStyle(.red)
                                .padding(.horizontal, 20)
                        }
                        Color.clear.frame(height: 4).id("bottom")
                    }
                    .padding(.horizontal, 20).padding(.vertical, 16)
                }
                .onChange(of: conversation.messages.last?.content) { _, _ in
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: conversation.id) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            Divider()
            ChatComposerView(
                text: $composerText,
                pendingAttachments: $pendingAttachments,
                attachmentError: $attachmentError,
                webSearchEnabled: Binding(
                    get: { conversation.webSearchEnabled },
                    set: { store.setWebSearch($0, in: conversation.id) }
                ),
                isStreaming: session.isStreaming,
                imagesAllowed: registry.activeRuntime?.definition.backend == .llamaCpp,
                onSend: {
                    let t = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty || !pendingAttachments.isEmpty else { return }
                    let attachments = pendingAttachments
                    let search = conversation.webSearchEnabled
                    composerText = ""
                    pendingAttachments = []
                    attachmentError = nil
                    session.send(userText: t, attachments: attachments, webSearch: search, in: conversation.id)
                },
                onStop: { session.stop() },
                onRegenerate: { session.regenerate(in: conversation.id) },
                canRegenerate: conversation.messages.contains { $0.role == .assistant }
            )
        }
    }
}
