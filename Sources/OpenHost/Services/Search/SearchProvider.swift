import Foundation

struct SearchResult: Codable, Sendable, Identifiable {
    var id: String { url }
    let title: String
    let url: String
    let snippet: String
}

enum SearchError: LocalizedError {
    case missingKey(String)
    case missingURL
    case badStatus(Int, String)
    case emptyResults
    case networkFailure(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider): return "\(provider) requires an API key. Add one in Settings."
        case .missingURL: return "SearXNG requires a base URL in Settings."
        case .badStatus(let code, let body): return "Search provider HTTP \(code): \(body.prefix(200))"
        case .emptyResults: return "No results."
        case .networkFailure(let msg): return "Search failed: \(msg)"
        }
    }
}

protocol SearchProvider: Sendable {
    var kind: SearchProviderKind { get }
    func search(query: String, maxResults: Int) async throws -> [SearchResult]
}

extension SearchResult {
    static func format(_ results: [SearchResult], for query: String) -> String {
        guard !results.isEmpty else { return "" }
        var out = "[Web search results for \"\(query)\"]\n"
        for (i, r) in results.enumerated() {
            out += "\(i + 1). \(r.title)\n   \(r.url)\n   \(r.snippet)\n"
        }
        out += "\n"
        return out
    }
}
