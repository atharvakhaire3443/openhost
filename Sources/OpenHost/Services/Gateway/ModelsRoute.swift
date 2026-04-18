import Foundation
import Hummingbird

enum ModelsRoute {
    static func list() async throws -> Response {
        let runtimes = await MainActor.run { ModelRegistry.shared.orderedRuntimes }
        var items: [[String: Any]] = []
        for rt in runtimes {
            let (state, reachable, resolvedID) = await MainActor.run {
                (rt.state, rt.isReachable, rt.resolvedModelId)
            }
            let def = rt.definition
            items.append([
                "id": def.apiModelName,
                "object": "model",
                "owned_by": def.backend.rawValue,
                "created": Int(Date().timeIntervalSince1970),
                "openhost": [
                    "display_name": def.displayName,
                    "port": def.port,
                    "state": state.label,
                    "is_reachable": reachable,
                    "upstream_id": resolvedID ?? NSNull(),
                    "max_context": def.maxContext,
                    "approx_memory_gb": def.approxMemoryGB
                ]
            ])
        }
        let payload: [String: Any] = ["object": "list", "data": items]
        return try jsonResponse(payload)
    }

    static func start(id: String) async throws -> Response {
        let runtime = await MainActor.run {
            ModelRegistry.shared.orderedRuntimes.first {
                $0.definition.apiModelName == id || $0.definition.id == id
            }
        }
        guard let runtime else {
            return try jsonResponse(["error": "model not found: \(id)"], status: .notFound)
        }
        await MainActor.run {
            Task { await ModelRegistry.shared.start(runtime) }
        }
        return try jsonResponse(["ok": true, "id": runtime.definition.apiModelName])
    }

    static func stop(id: String) async throws -> Response {
        let runtime = await MainActor.run {
            ModelRegistry.shared.orderedRuntimes.first {
                $0.definition.apiModelName == id || $0.definition.id == id
            }
        }
        guard let runtime else {
            return try jsonResponse(["error": "model not found: \(id)"], status: .notFound)
        }
        await MainActor.run {
            Task { await runtime.stop() }
        }
        return try jsonResponse(["ok": true, "id": runtime.definition.apiModelName])
    }
}

func jsonResponse(_ payload: Any, status: HTTPResponse.Status = .ok) throws -> Response {
    let data = try JSONSerialization.data(withJSONObject: payload)
    var buf = ByteBuffer()
    buf.writeBytes(data)
    var response = Response(status: status, body: .init(byteBuffer: buf))
    response.headers[.contentType] = "application/json"
    return response
}
