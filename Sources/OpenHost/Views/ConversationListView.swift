import SwiftUI

struct ConversationListView: View {
    @ObservedObject var store: ChatStore
    @State private var renamingID: UUID?
    @State private var renameText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Chats").font(.title3.weight(.semibold))
                Spacer()
                Button {
                    store.new()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New chat")
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.conversations) { convo in
                        convoRow(convo)
                    }
                }
                .padding(.horizontal, 10)
            }
            Spacer()
        }
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func convoRow(_ convo: Conversation) -> some View {
        let isSelected = store.selectedID == convo.id
        HStack(spacing: 8) {
            Image(systemName: "message")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if renamingID == convo.id {
                TextField("", text: $renameText, onCommit: {
                    store.rename(convo.id, to: renameText.isEmpty ? "Untitled" : renameText)
                    renamingID = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(convo.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(relativeDate(convo.updatedAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { store.selectedID = convo.id }
        .contextMenu {
            Button("Rename") {
                renameText = convo.title
                renamingID = convo.id
            }
            Button("Delete", role: .destructive) {
                store.delete(convo.id)
            }
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
