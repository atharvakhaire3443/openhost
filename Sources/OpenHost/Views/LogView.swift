import SwiftUI

struct LogView: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("LOGS").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Text("\(lines.count) lines").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 14)
                }
                .onChange(of: lines.count) { _, _ in
                    if let last = lines.indices.last {
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            .background(Color.black.opacity(0.04))
        }
    }

    private func color(for line: String) -> Color {
        let l = line.lowercased()
        if l.contains("error") || l.contains("traceback") { return .red }
        if l.contains("warn") { return .orange }
        if l.hasPrefix("[openhost]") { return .accentColor }
        return .primary.opacity(0.85)
    }
}
