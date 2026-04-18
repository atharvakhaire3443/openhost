import Foundation
import PDFKit
import UniformTypeIdentifiers
import AppKit

enum DocumentExtractorError: LocalizedError {
    case tooLarge(UInt64)
    case unreadable(String)
    case pdfFailed
    case binaryNotSupported(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let n): return "File too large (\(n / 1024 / 1024) MB). Limit 4 MB."
        case .unreadable(let s): return "Could not read file: \(s)"
        case .pdfFailed: return "Could not extract text from PDF."
        case .binaryNotSupported(let ext): return "Binary format .\(ext) not supported. Use text, code, or PDF."
        }
    }
}

struct DocumentExtractor {
    static let maxBytes: UInt64 = 4 * 1024 * 1024
    static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "rst",
        "py", "js", "ts", "tsx", "jsx", "swift", "go", "rs", "c", "cc", "cpp", "h", "hpp",
        "java", "kt", "rb", "php", "cs", "lua", "dart", "scala", "clj", "ex", "exs", "elm",
        "sh", "zsh", "bash", "fish", "ps1",
        "json", "yaml", "yml", "toml", "ini", "conf", "cfg", "env",
        "html", "htm", "xml", "svg", "css", "scss", "less",
        "sql", "graphql", "proto",
        "log", "csv", "tsv", "tex", "bib", "makefile", "dockerfile", "gitignore"
    ]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]

    static func extract(url: URL) throws -> MessageAttachment {
        let fm = FileManager.default
        let attrs = try fm.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? UInt64) ?? 0
        if size > maxBytes { throw DocumentExtractorError.tooLarge(size) }

        let ext = url.pathExtension.lowercased()

        if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else { throw DocumentExtractorError.pdfFailed }
            var out = ""
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i), let s = page.string {
                    out += s
                    out += "\n\n"
                }
            }
            if out.isEmpty { throw DocumentExtractorError.pdfFailed }
            return MessageAttachment(
                kind: .text,
                filename: url.lastPathComponent,
                mimeType: "application/pdf",
                byteSize: Int(size),
                payload: out
            )
        }

        if imageExtensions.contains(ext) {
            let data = try Data(contentsOf: url)
            let mime = mimeType(forExtension: ext)
            let b64 = data.base64EncodedString()
            return MessageAttachment(
                kind: .image,
                filename: url.lastPathComponent,
                mimeType: mime,
                byteSize: data.count,
                payload: "data:\(mime);base64,\(b64)"
            )
        }

        let filename = url.lastPathComponent.lowercased()
        let isKnownText = textExtensions.contains(ext)
            || filename == "makefile" || filename == "dockerfile" || filename == "readme"
            || ext == ""

        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            throw DocumentExtractorError.binaryNotSupported(ext.isEmpty ? "?" : ext)
        }

        if !isKnownText && text.unicodeScalars.contains(where: { $0.value == 0 }) {
            throw DocumentExtractorError.binaryNotSupported(ext.isEmpty ? "?" : ext)
        }

        return MessageAttachment(
            kind: .text,
            filename: url.lastPathComponent,
            mimeType: mimeType(forExtension: ext),
            byteSize: data.count,
            payload: text
        )
    }

    private static func mimeType(forExtension ext: String) -> String {
        if let t = UTType(filenameExtension: ext), let m = t.preferredMIMEType { return m }
        switch ext {
        case "md": return "text/markdown"
        case "json": return "application/json"
        case "pdf": return "application/pdf"
        default: return "text/plain"
        }
    }

    @MainActor
    static func pickFiles(imagesAllowed: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = [.plainText, .sourceCode, .pdf, .json, .xml, .yaml, .html, .delimitedText, .commaSeparatedText]
        if imagesAllowed { types.append(contentsOf: [.png, .jpeg, .gif, .webP, .bmp]) }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        return panel.runModal() == .OK ? panel.urls : []
    }
}
