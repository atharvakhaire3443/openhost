import Foundation
import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String {
    case markdown = "md"
    case json = "json"
}

struct ChatExporter {
    @MainActor
    static func export(_ conversation: Conversation, format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sanitizeFilename(conversation.title)).\(format.rawValue)"
        panel.allowedContentTypes = format == .markdown
            ? [UTType(filenameExtension: "md") ?? .plainText]
            : [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let data: Data
        switch format {
        case .markdown:
            data = renderMarkdown(conversation).data(using: .utf8) ?? Data()
        case .json:
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = (try? enc.encode(conversation)) ?? Data()
        }
        try? data.write(to: url, options: .atomic)
    }

    private static func sanitizeFilename(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return s.components(separatedBy: bad).joined(separator: "-").prefix(60).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func renderMarkdown(_ c: Conversation) -> String {
        var out = "# \(c.title)\n\n"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        out += "_Created: \(df.string(from: c.createdAt))_  ·  _Updated: \(df.string(from: c.updatedAt))_\n\n"
        if !c.settings.systemPrompt.isEmpty {
            out += "## System\n\n> \(c.settings.systemPrompt.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
        }
        for m in c.messages {
            let header: String
            switch m.role {
            case .user: header = "## You"
            case .assistant:
                var h = "## Assistant"
                if let s = m.stats {
                    var bits: [String] = []
                    if let b = s.backend { bits.append(b) }
                    if let tps = s.tokensPerSecond { bits.append(String(format: "%.1f tok/s", tps)) }
                    if let ct = s.completionTokens { bits.append("\(ct) tok") }
                    if !bits.isEmpty { h += " _(\(bits.joined(separator: ", ")))_" }
                }
                header = h
            case .system: header = "## System"
            }
            out += "\(header)\n\n"
            for a in m.attachments where a.kind == .text {
                out += "**Attached: \(a.filename)** (\(a.displaySize))\n\n```\n\(a.payload)\n```\n\n"
            }
            for a in m.attachments where a.kind == .image {
                out += "_[image: \(a.filename), \(a.displaySize)]_\n\n"
            }
            out += "\(m.content)\n\n"
        }
        return out
    }
}
