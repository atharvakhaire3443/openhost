import Foundation

/// Minimal multipart/form-data parser. Handles the single-file-upload case
/// (e.g. OpenAI-compatible `/v1/audio/transcriptions`). Not a general-purpose parser.
struct MultipartPart {
    var headers: [String: String]
    var body: Data

    var name: String? { disposition("name") }
    var filename: String? { disposition("filename") }
    var contentType: String? { headers["Content-Type"] ?? headers["content-type"] }

    private func disposition(_ key: String) -> String? {
        guard let value = headers["Content-Disposition"] ?? headers["content-disposition"]
        else { return nil }
        for segment in value.components(separatedBy: ";") {
            let s = segment.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("\(key)=") {
                let raw = String(s.dropFirst(key.count + 1))
                return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }
}

enum Multipart {
    /// Extract the `boundary` parameter from a `multipart/form-data; boundary=...` header.
    static func boundary(fromContentType header: String) -> String? {
        for seg in header.components(separatedBy: ";") {
            let s = seg.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("boundary=") {
                let raw = String(s.dropFirst("boundary=".count))
                return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    static func parse(data: Data, boundary: String) -> [MultipartPart] {
        guard let boundaryData = "--\(boundary)".data(using: .utf8) else { return [] }
        let crlf = Data([0x0D, 0x0A])
        let crlfCRLF = Data([0x0D, 0x0A, 0x0D, 0x0A])

        var parts: [MultipartPart] = []
        var cursor = 0

        while let startRange = data.range(of: boundaryData, in: cursor..<data.count) {
            cursor = startRange.upperBound
            // Closing boundary is "--boundary--"
            if cursor + 1 < data.count, data[cursor] == 0x2D, data[cursor + 1] == 0x2D {
                break
            }
            // Skip the CRLF after the boundary
            if cursor + 1 < data.count, data[cursor] == 0x0D, data[cursor + 1] == 0x0A {
                cursor += 2
            }

            // Find end of headers (blank line: CRLFCRLF)
            guard let headerEnd = data.range(of: crlfCRLF, in: cursor..<data.count) else { break }
            let headersRaw = data[cursor..<headerEnd.lowerBound]
            let headersString = String(data: headersRaw, encoding: .utf8) ?? ""
            var headers: [String: String] = [:]
            for line in headersString.components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
            cursor = headerEnd.upperBound

            // Body ends at the next boundary marker (preceded by CRLF).
            guard let nextBoundaryRange = data.range(of: boundaryData, in: cursor..<data.count) else { break }
            var bodyEnd = nextBoundaryRange.lowerBound
            // Strip the trailing CRLF before the boundary.
            if bodyEnd >= cursor + 2,
               data[bodyEnd - 2] == 0x0D,
               data[bodyEnd - 1] == 0x0A {
                bodyEnd -= 2
            }
            let body = Data(data[cursor..<bodyEnd])
            parts.append(MultipartPart(headers: headers, body: body))

            cursor = nextBoundaryRange.lowerBound
            _ = crlf // suppress warning
        }

        return parts
    }
}
