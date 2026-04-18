import Foundation

struct DuckDuckGoProvider: SearchProvider {
    let kind: SearchProviderKind = .duckduckgo

    func search(query: String, maxResults: Int) async throws -> [SearchResult] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            throw SearchError.networkFailure("invalid URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SearchError.networkFailure("no response") }
        guard (200...299).contains(http.statusCode) else {
            throw SearchError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw SearchError.networkFailure("non-UTF8 body")
        }

        let results = Self.parse(html: html, limit: maxResults)
        if results.isEmpty { throw SearchError.emptyResults }
        return results
    }

    static func parse(html: String, limit: Int) -> [SearchResult] {
        var results: [SearchResult] = []
        let linkPattern = #"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#
        let snippetPattern = #"<a[^>]*class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)</a>"#

        let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive])
        let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: [.caseInsensitive])
        let range = NSRange(html.startIndex..., in: html)

        let linkMatches = linkRegex?.matches(in: html, range: range) ?? []
        let snippetMatches = snippetRegex?.matches(in: html, range: range) ?? []

        let snippets = snippetMatches.compactMap { m -> String? in
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: html) else { return nil }
            return cleanHTML(String(html[r]))
        }

        for (i, m) in linkMatches.enumerated() {
            if results.count >= limit { break }
            guard m.numberOfRanges > 2,
                  let urlRange = Range(m.range(at: 1), in: html),
                  let titleRange = Range(m.range(at: 2), in: html)
            else { continue }
            let rawURL = String(html[urlRange])
            let url = resolveDDGRedirect(rawURL)
            let title = cleanHTML(String(html[titleRange]))
            let snippet = i < snippets.count ? snippets[i] : ""
            results.append(SearchResult(title: title, url: url, snippet: snippet))
        }
        return results
    }

    private static func resolveDDGRedirect(_ href: String) -> String {
        let fullPrefix = "//duckduckgo.com/l/?uddg="
        if let r = href.range(of: fullPrefix) {
            let tail = String(href[r.upperBound...])
            if let end = tail.firstIndex(of: "&") {
                let enc = String(tail[..<end])
                return enc.removingPercentEncoding ?? enc
            } else {
                return tail.removingPercentEncoding ?? tail
            }
        }
        if href.hasPrefix("//") { return "https:" + href }
        return href
    }

    private static func cleanHTML(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        out = out.replacingOccurrences(of: "&quot;", with: "\"")
        out = out.replacingOccurrences(of: "&#x27;", with: "'")
        out = out.replacingOccurrences(of: "&#39;", with: "'")
        out = out.replacingOccurrences(of: "&lt;", with: "<")
        out = out.replacingOccurrences(of: "&gt;", with: ">")
        out = out.replacingOccurrences(of: "&nbsp;", with: " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
