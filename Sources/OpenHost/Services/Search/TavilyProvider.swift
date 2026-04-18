import Foundation

struct TavilyProvider: SearchProvider {
    let kind: SearchProviderKind = .tavily
    let apiKey: String

    func search(query: String, maxResults: Int) async throws -> [SearchResult] {
        guard !apiKey.isEmpty else { throw SearchError.missingKey("Tavily") }
        guard let url = URL(string: "https://api.tavily.com/search") else {
            throw SearchError.networkFailure("invalid URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 10

        let body: [String: Any] = [
            "api_key": apiKey,
            "query": query,
            "max_results": maxResults,
            "search_depth": "basic",
            "include_answer": false
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

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
            let snippet = (d["content"] as? String) ?? (d["snippet"] as? String) ?? ""
            return SearchResult(title: title, url: url, snippet: snippet)
        }
        if results.isEmpty { throw SearchError.emptyResults }
        return results
    }
}
