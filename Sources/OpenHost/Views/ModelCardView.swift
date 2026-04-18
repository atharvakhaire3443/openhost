import SwiftUI

struct ModelCardView: View {
    @ObservedObject var runtime: ModelRuntime
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(state: runtime.state, reachable: runtime.isReachable)
            VStack(alignment: .leading, spacing: 2) {
                Text(runtime.definition.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text("\(runtime.definition.backend.rawValue) · :\(runtime.definition.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(runtime.state.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.accentColor.opacity(0.5) : Color.gray.opacity(0.15), lineWidth: 1)
        )
    }
}

struct StatusDot: View {
    let state: RunState
    let reachable: Bool

    var color: Color {
        switch state {
        case .running: return reachable ? .green : .yellow
        case .starting, .stopping: return .yellow
        case .crashed: return .red
        case .stopped: return .gray.opacity(0.5)
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(.black.opacity(0.1), lineWidth: 0.5))
    }
}
