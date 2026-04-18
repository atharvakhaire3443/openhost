import SwiftUI

struct ChatStatsBar: View {
    @ObservedObject var registry: ModelRegistry
    @ObservedObject var session: ChatSession
    let conversation: Conversation?

    var body: some View {
        HStack(spacing: 16) {
            backendPill
            if session.isStreaming {
                liveStat("TTFT", value: session.liveTTFTms.map { "\($0) ms" } ?? "—")
                liveStat("tok/s", value: String(format: "%.1f", session.liveTokensPerSecond))
                liveStat("chars", value: "\(session.liveCompletionChars)")
            } else if let last = conversation?.messages.last(where: { $0.role == .assistant }), let s = last.stats, s.tokensPerSecond != nil {
                liveStat("last tok/s", value: String(format: "%.1f", s.tokensPerSecond ?? 0))
                if let t = s.ttftMs { liveStat("TTFT", value: "\(t) ms") }
                if let c = s.completionTokens { liveStat("out", value: "\(c)") }
            }
            Spacer()
            contextGauge
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var backendPill: some View {
        if let rt = registry.activeRuntime, rt.state == .running {
            HStack(spacing: 6) {
                Circle().fill(rt.isReachable ? Color.green : Color.yellow).frame(width: 7, height: 7)
                Text(rt.definition.backend.rawValue).font(.system(size: 11, weight: .medium))
                Text("·").foregroundStyle(.secondary)
                Text(rt.definition.displayName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.green.opacity(0.1)))
        } else {
            HStack(spacing: 6) {
                Circle().fill(Color.gray).frame(width: 7, height: 7)
                Text("No model running").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.1)))
        }
    }

    private func liveStat(_ label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
    }

    @ViewBuilder
    private var contextGauge: some View {
        if let convo = conversation {
            let used = convo.promptTokensApprox
            let cap = registry.activeRuntime?.definition.maxContext ?? 32768
            let pct = min(1.0, Double(used) / Double(cap))
            HStack(spacing: 8) {
                Text("context").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 80, height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(pct > 0.85 ? Color.orange : Color.accentColor)
                        .frame(width: max(3, 80 * pct), height: 6)
                }
                Text("\(used)/\(cap)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
