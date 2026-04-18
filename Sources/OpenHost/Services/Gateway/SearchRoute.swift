import Foundation
import Hummingbird

enum SearchRoute {
    static func handle(request: Request, context: BasicRequestContext) async throws -> Response {
        let bodyData = try await request.body.collect(upTo: 1 * 1024 * 1024)
        let bodyBytes = bodyData.getBytes(at: 0, length: bodyData.readableBytes) ?? []

        guard let json = try? JSONSerialization.jsonObject(with: Data(bodyBytes)) as? [String: Any],
              let query = (json["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty
        else {
            return try jsonResponse(["error": "missing or empty 'query' field"], status: .badRequest)
        }
        let maxResults = (json["max_results"] as? Int) ?? 5

        let provider = await MainActor.run {
            SearchRouter.makeProvider(from: AppSettings.shared)
        }
        do {
            let results = try await provider.search(query: query, maxResults: maxResults)
            let payload: [String: Any] = [
                "query": query,
                "provider": provider.kind.rawValue,
                "results": results.map {
                    [
                        "title": $0.title,
                        "url": $0.url,
                        "snippet": $0.snippet
                    ]
                }
            ]
            return try jsonResponse(payload)
        } catch {
            return try jsonResponse([
                "error": error.localizedDescription,
                "provider": provider.kind.rawValue
            ], status: .internalServerError)
        }
    }
}
