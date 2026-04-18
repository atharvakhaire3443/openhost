import Foundation

struct SearXNGProvider: SearchProvider {
    let kind: SearchProviderKind = .searxng
    let baseURL: String

    func search(query: String, maxResults: Int) async throws -> [SearchResult] {
        guard !baseURL.isEmpty else { throw SearchError.missingURL }
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        if base.hasSuffix("/") { base.removeLast() }
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(base)/search?q=\(encoded)&format=json") else {
            throw SearchError.networkFailure("invalid URL: \(base)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SearchError.networkFailure("no response") }
        guard (200...299).contains(http.statusCode) else {
            throw SearchError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["results"] as? [[String: Any]]
        else { throw SearchError.emptyResults }

        let results = arr.prefix(maxResults).compactMap { d -> SearchResult? in
            guard let title = d["title"] as? String,
                  let url = d["url"] as? String else { return nil }
            let snippet = (d["content"] as? String) ?? ""
            return SearchResult(title: title, url: url, snippet: snippet)
        }
        if results.isEmpty { throw SearchError.emptyResults }
        return results
    }
}
