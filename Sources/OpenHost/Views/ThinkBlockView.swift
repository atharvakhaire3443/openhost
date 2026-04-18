import SwiftUI

struct ThinkBlockView: View {
    let content: String
    let closed: Bool
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Image(systemName: closed ? "brain" : "brain.filled.head.profile")
                        .font(.system(size: 10))
                    Text(closed ? "Thinking" : "Thinking…")
                        .font(.system(size: 11, weight: .medium))
                    if !closed { AnimatedDot() }
                    Text("(\(content.count) chars)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
            )

            if expanded {
                ScrollView {
                    Text(content)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 280)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.05)))
                .padding(.top, 4)
            }
        }
        .onChange(of: closed) { _, newValue in
            if newValue { expanded = false }
        }
    }
}

private struct AnimatedDot: View {
    @State private var phase: Double = 0
    var body: some View {
        Circle()
            .fill(Color.secondary)
            .frame(width: 5, height: 5)
            .opacity(0.4 + 0.6 * phase)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    phase = 1
                }
            }
    }
}
