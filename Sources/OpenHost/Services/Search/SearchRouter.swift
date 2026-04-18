import Foundation

struct SearchRouter {
    @MainActor
    static func makeProvider(from settings: AppSettings) -> SearchProvider {
        switch settings.searchProvider {
        case .duckduckgo: return DuckDuckGoProvider()
        case .tavily: return TavilyProvider(apiKey: settings.tavilyKey)
        case .brave: return BraveProvider(apiKey: settings.braveKey)
        case .searxng: return SearXNGProvider(baseURL: settings.searxngURL)
        }
    }
}
