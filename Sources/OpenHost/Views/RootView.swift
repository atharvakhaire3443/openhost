import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case models = "Models"
    case chat = "Chat"
    case transcribe = "Transcribe"
    case settings = "Settings"
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .models: return "cpu"
        case .chat: return "message"
        case .transcribe: return "waveform"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @State private var tab: AppTab = .models

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("OpenHost")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 14)
                    .padding(.trailing, 18)
                ForEach(AppTab.allCases) { t in
                    Button {
                        tab = t
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: t.systemImage).font(.system(size: 11))
                            Text(t.rawValue).font(.system(size: 12, weight: tab == t ? .semibold : .regular))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(tab == t ? Color.accentColor.opacity(0.18) : Color.clear)
                        )
                        .foregroundStyle(tab == t ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(.regularMaterial)

            Divider()

            Group {
                switch tab {
                case .models: ModelsView()
                case .chat: ChatView()
                case .transcribe: TranscribeView()
                case .settings: SettingsView()
                }
            }
        }
    }
}

struct ModelsView: View {
    @EnvironmentObject var registry: ModelRegistry
    @State private var selectedId: String?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
            detail
                .frame(minWidth: 520)
        }
        .onAppear {
            if selectedId == nil {
                selectedId = registry.orderedRuntimes.first?.id
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MODELS")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(registry.orderedRuntimes) { rt in
                        ModelCardView(runtime: rt, selected: rt.id == selectedId)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedId = rt.id }
                    }
                }
                .padding(.horizontal, 14)
            }

            Spacer()
            Divider()
            Text("One model at a time — switching stops the running one.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(14)
        }
        .background(.regularMaterial)
    }

    private var detail: some View {
        Group {
            if let id = selectedId, let rt = registry.runtimes[id] {
                DetailView(runtime: rt)
            } else {
                Text("Select a model").foregroundStyle(.secondary)
            }
        }
    }
}
