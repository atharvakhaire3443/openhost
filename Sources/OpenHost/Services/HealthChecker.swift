import Foundation

struct HealthProbe {
    let reachable: Bool
    let modelId: String?
}

struct HealthChecker {
    let port: Int

    func probe() async -> HealthProbe {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else {
            return HealthProbe(reachable: false, modelId: nil)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 1.5
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return HealthProbe(reachable: false, modelId: nil)
            }
            var modelId: String?
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = json["data"] as? [[String: Any]],
               let first = arr.first,
               let id = first["id"] as? String {
                modelId = id
            }
            return HealthProbe(reachable: true, modelId: modelId)
        } catch {
            return HealthProbe(reachable: false, modelId: nil)
        }
    }
}
