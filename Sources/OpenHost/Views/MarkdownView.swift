import SwiftUI
import AppKit

enum MDBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case code(language: String?, content: String)
    case bulletList([String])
    case orderedList([String])
    case quote(String)
    case hr
    case think(content: String, closed: Bool)
}

struct MarkdownView: View {
    let text: String

    var body: some View {
        let blocks = Self.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { idx in
                render(blocks[idx])
            }
        }
    }

    @ViewBuilder
    private func render(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            headingText(text, level: level)
        case .paragraph(let text):
            inlineText(text)
        case .code(let lang, let content):
            codeBlock(lang: lang, content: content)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inlineText(items[i])
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1).").foregroundStyle(.secondary).monospacedDigit()
                        inlineText(items[i])
                    }
                }
            }
        case .quote(let text):
            HStack(spacing: 10) {
                Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
                inlineText(text).italic().foregroundStyle(.secondary)
            }
        case .hr:
            Rectangle().fill(Color.secondary.opacity(0.2)).frame(height: 1)
        case .think(let content, let closed):
            ThinkBlockView(content: content, closed: closed)
        }
    }

    @ViewBuilder
    private func headingText(_ text: String, level: Int) -> some View {
        let size: CGFloat = level == 1 ? 18 : level == 2 ? 16 : 14
        if let attr = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attr).font(.system(size: size, weight: .semibold)).padding(.top, 4)
        } else {
            Text(text).font(.system(size: size, weight: .semibold)).padding(.top, 4)
        }
    }

    @ViewBuilder
    private func inlineText(_ text: String) -> some View {
        if let attr = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attr).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func codeBlock(lang: String?, content: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang?.isEmpty == false ? lang! : "code")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("Copy code")
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(10)
                    .textSelection(.enabled)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Parser

    static func parse(_ text: String) -> [MDBlock] {
        let segments = splitThinkSegments(text)
        var all: [MDBlock] = []
        for seg in segments {
            switch seg {
            case .think(let content, let closed):
                all.append(.think(content: content.trimmingCharacters(in: .whitespacesAndNewlines), closed: closed))
            case .normal(let body):
                all.append(contentsOf: parseNormal(body))
            }
        }
        return all
    }

    private enum Segment {
        case normal(String)
        case think(String, Bool)
    }

    private static func splitThinkSegments(_ text: String) -> [Segment] {
        var result: [Segment] = []
        var rest = text[text.startIndex..<text.endIndex]
        while let openRange = rest.range(of: "<think>") {
            let before = rest[rest.startIndex..<openRange.lowerBound]
            if !before.isEmpty { result.append(.normal(String(before))) }
            let afterOpen = rest[openRange.upperBound..<rest.endIndex]
            if let closeRange = afterOpen.range(of: "</think>") {
                let content = afterOpen[afterOpen.startIndex..<closeRange.lowerBound]
                result.append(.think(String(content), true))
                rest = afterOpen[closeRange.upperBound..<afterOpen.endIndex]
            } else {
                result.append(.think(String(afterOpen), false))
                return result
            }
        }
        if !rest.isEmpty { result.append(.normal(String(rest))) }
        return result
    }

    private static func parseNormal(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var content: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    content.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: lang.isEmpty ? nil : lang, content: content.joined(separator: "\n")))
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.hr); i += 1; continue
            }

            // Heading
            if let level = headingLevel(trimmed) {
                let stripped = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: stripped))
                i += 1
                continue
            }

            // Blockquote
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                var quoteLines: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        quoteLines.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                        i += 1
                    } else { break }
                }
                blocks.append(.quote(quoteLines.joined(separator: " ")))
                continue
            }

            // Bullet list
            if isBullet(trimmed) {
                var items: [String] = []
                while i < lines.count, isBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripBullet(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Ordered list
            if isOrdered(trimmed) {
                var items: [String] = []
                while i < lines.count, isOrdered(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripOrdered(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            // Blank line → skip
            if trimmed.isEmpty { i += 1; continue }

            // Paragraph: accumulate until blank line or block starter
            var para: [String] = [line]
            i += 1
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if t.hasPrefix("```") || headingLevel(t) != nil || t.hasPrefix("> ") || isBullet(t) || isOrdered(t) { break }
                para.append(lines[i])
                i += 1
            }
            blocks.append(.paragraph(para.joined(separator: "\n")))
        }
        return blocks
    }

    private static func headingLevel(_ s: String) -> Int? {
        guard s.hasPrefix("#") else { return nil }
        var level = 0
        for c in s {
            if c == "#" { level += 1 } else { break }
        }
        guard level >= 1 && level <= 6 else { return nil }
        let rest = String(s.dropFirst(level))
        guard rest.hasPrefix(" ") || rest.isEmpty else { return nil }
        return level
    }

    private static func isBullet(_ s: String) -> Bool {
        s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ")
    }
    private static func stripBullet(_ s: String) -> String {
        String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }
    private static func isOrdered(_ s: String) -> Bool {
        guard let firstSpace = s.firstIndex(of: " ") else { return false }
        let prefix = s[..<firstSpace]
        guard prefix.hasSuffix(".") else { return false }
        return prefix.dropLast().allSatisfy { $0.isNumber }
    }
    private static func stripOrdered(_ s: String) -> String {
        guard let firstSpace = s.firstIndex(of: " ") else { return s }
        return String(s[s.index(after: firstSpace)...]).trimmingCharacters(in: .whitespaces)
    }
}
