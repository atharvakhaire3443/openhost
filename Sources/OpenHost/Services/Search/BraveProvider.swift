import Foundation

struct BraveProvider: SearchProvider {
    let kind: SearchProviderKind = .brave
    let apiKey: String

    func search(query: String, maxResults: Int) async throws -> [SearchResult] {
        guard !apiKey.isEmpty else { throw SearchError.missingKey("Brave") }
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.search.brave.com/res/v1/web/search?q=\(encoded)&count=\(maxResults)") else {
            throw SearchError.networkFailure("invalid URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SearchError.networkFailure("no response") }
        guard (200...299).contains(http.statusCode) else {
            throw SearchError.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = json["web"] as? [String: Any],
              let arr = web["results"] as? [[String: Any]]
        else { throw SearchError.emptyResults }

        let results = arr.prefix(maxResults).compactMap { d -> SearchResult? in
            guard let title = d["title"] as? String,
                  let url = d["url"] as? String else { return nil }
            let snippet = (d["description"] as? String) ?? ""
            return SearchResult(title: stripHTML(title), url: url, snippet: stripHTML(snippet))
        }
        if results.isEmpty { throw SearchError.emptyResults }
        return results
    }

    private func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }
}
