import SwiftUI

struct AttachmentChipView: View {
    let attachment: MessageAttachment
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.filename)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(attachment.displaySize)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(tint.opacity(0.25), lineWidth: 0.5)
        )
    }

    private var icon: String {
        switch attachment.kind {
        case .text: return attachment.mimeType == "application/pdf" ? "doc.richtext" : "doc.text"
        case .image: return "photo"
        }
    }

    private var tint: Color {
        switch attachment.kind {
        case .text: return .blue
        case .image: return .purple
        }
    }
}
