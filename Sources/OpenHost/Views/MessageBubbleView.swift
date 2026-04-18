import SwiftUI

struct MessageBubbleView: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(roleLabel).font(.caption.weight(.semibold))
                    if let stats = message.stats, message.role == .assistant, stats.tokensPerSecond != nil {
                        statsLine(stats)
                    }
                    Spacer()
                    Button {
                        copyToPasteboard(message.content)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                    .opacity(0.6)
                }

                if !message.attachments.isEmpty {
                    attachmentsRow
                }
                if message.content.isEmpty && message.role == .assistant {
                    ThinkingDots()
                } else if !message.content.isEmpty {
                    renderedText
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var avatar: some View {
        ZStack {
            Circle().fill(bubbleTint.opacity(0.25)).frame(width: 26, height: 26)
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(bubbleTint)
        }
    }

    private var iconName: String {
        switch message.role {
        case .user: return "person.fill"
        case .assistant: return "sparkle"
        case .system: return "gear"
        }
    }

    private var bubbleTint: Color {
        switch message.role {
        case .user: return .blue
        case .assistant: return .purple
        case .system: return .gray
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "You"
        case .assistant: return "Assistant"
        case .system: return "System"
        }
    }

    @ViewBuilder
    private var attachmentsRow: some View {
        let imageAttachments = message.attachments.filter { $0.kind == .image }
        let textAttachments = message.attachments.filter { $0.kind == .text }
        VStack(alignment: .leading, spacing: 6) {
            if !textAttachments.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(textAttachments) { a in
                        AttachmentChipView(attachment: a)
                    }
                }
            }
            if !imageAttachments.isEmpty {
                HStack(spacing: 6) {
                    ForEach(imageAttachments) { a in
                        if let data = dataURLToData(a.payload), let img = NSImage(data: data) {
                            Image(nsImage: img)
                                .resizable().scaledToFill()
                                .frame(width: 120, height: 90)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            AttachmentChipView(attachment: a)
                        }
                    }
                }
            }
        }
    }

    private func dataURLToData(_ url: String) -> Data? {
        guard let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
        return data
    }

    @ViewBuilder
    private var renderedText: some View {
        if message.role == .assistant {
            MarkdownView(text: message.content)
        } else {
            Text(message.content).font(.system(size: 13))
        }
    }

    @ViewBuilder
    private func statsLine(_ s: MessageStats) -> some View {
        HStack(spacing: 10) {
            if let tps = s.tokensPerSecond {
                Label(String(format: "%.1f tok/s", tps), systemImage: "gauge.with.needle")
            }
            if let ttft = s.ttftMs {
                Label("\(ttft) ms TTFT", systemImage: "timer")
            }
            if let ct = s.completionTokens {
                Label("\(ct) tok", systemImage: "text.alignleft")
            }
            if let b = s.backend {
                Text(b)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }
        }
        .font(.system(size: 10, weight: .regular, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    private func copyToPasteboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

struct ThinkingDots: View {
    @State private var phase: Int = 0
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1 : 0.3)
            }
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}
