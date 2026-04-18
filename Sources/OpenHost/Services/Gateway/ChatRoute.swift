import Foundation
import Hummingbird
import HTTPTypes

enum ChatRoute {
    /// Proxies POST /v1/chat/completions to whichever local model is currently active.
    /// Supports both streaming (SSE) and non-streaming bodies.
    static func proxy(request: Request, context: BasicRequestContext) async throws -> Response {
        // Determine which model to route to. Prefer the currently-active runtime;
        // if none is running, fall back to the model named in the request body.
        let bodyData = try await request.body.collect(upTo: 16 * 1024 * 1024)
        let bodyBytes = bodyData.getBytes(at: 0, length: bodyData.readableBytes) ?? []
        let bodyBlob = Data(bodyBytes)

        let active = await MainActor.run { ModelRegistry.shared.activeRuntime }
        let targetPort: Int
        let upstreamModelID: String?
        let isActiveUsable: Bool = await {
            guard let active else { return false }
            return await MainActor.run {
                active.state == .running && active.isReachable
            }
        }()
        if let active, isActiveUsable {
            targetPort = active.definition.port
            upstreamModelID = await MainActor.run { active.effectiveApiModelName }
        } else {
            // Try to resolve from body.model → port.
            if let json = try? JSONSerialization.jsonObject(with: bodyBlob) as? [String: Any],
               let modelID = json["model"] as? String,
               let def = ModelDefinition.all.first(where: { $0.apiModelName == modelID || $0.id == modelID }) {
                targetPort = def.port
                upstreamModelID = nil
            } else {
                return try jsonResponse([
                    "error": [
                        "message": "No model is running. Start one via POST /v1/models/{id}/start or the OpenHost app.",
                        "type": "no_active_model"
                    ]
                ], status: .serviceUnavailable)
            }
        }

        // If the gateway's cached upstream id is empty (e.g. model just started
        // and the health probe hasn't populated it yet), ask the upstream directly.
        var resolvedID = upstreamModelID
        if resolvedID == nil {
            resolvedID = try await discoverUpstreamID(port: targetPort, maxWait: 30)
        }

        // Rewrite `model` field to whatever the upstream server advertises.
        // Users can pass "qwen3.6-35b-mlx" (friendly), but mlx_lm.server only accepts
        // its own self-advertised id (typically the absolute model path).
        let finalBody: Data = {
            guard let id = resolvedID,
                  var json = try? JSONSerialization.jsonObject(with: bodyBlob) as? [String: Any]
            else { return bodyBlob }
            json["model"] = id
            return (try? JSONSerialization.data(withJSONObject: json)) ?? bodyBlob
        }()

        guard let url = URL(string: "http://127.0.0.1:\(targetPort)/v1/chat/completions") else {
            return try jsonResponse(["error": "invalid upstream url"], status: .internalServerError)
        }
        NSLog("[openhost] Gateway: proxy → :%d model=%@ bytes=%d", targetPort, upstreamModelID ?? "—", finalBody.count)

        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.httpBody = finalBody
        urlReq.timeoutInterval = 600
        for field in request.headers {
            if field.name == .contentLength { continue }
            urlReq.setValue(field.value, forHTTPHeaderField: field.name.rawName)
        }
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Determine if streaming was requested
        let isStream: Bool = {
            guard let json = try? JSONSerialization.jsonObject(with: bodyBlob) as? [String: Any] else {
                return false
            }
            return (json["stream"] as? Bool) ?? false
        }()

        if isStream {
            NSLog("[openhost] Gateway: streaming mode")
            return try await streamFromUpstream(request: urlReq)
        } else {
            NSLog("[openhost] Gateway: non-streaming, awaiting upstream…")
            let started = Date()
            do {
                let (data, response) = try await URLSession.shared.data(for: urlReq)
                let http = response as? HTTPURLResponse
                NSLog("[openhost] Gateway: upstream responded status=%d bytes=%d in %.2fs",
                      http?.statusCode ?? -1, data.count, Date().timeIntervalSince(started))
                var buf = ByteBuffer()
                buf.writeBytes(data)
                let status = HTTPResponse.Status(code: http?.statusCode ?? 502)
                var resp = Response(status: status, body: .init(byteBuffer: buf))
                resp.headers[.contentType] = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
                return resp
            } catch {
                NSLog("[openhost] Gateway: upstream error: %@", error.localizedDescription)
                return try jsonResponse([
                    "error": ["message": "Upstream error: \(error.localizedDescription)"]
                ], status: .badGateway)
            }
        }
    }

    /// Probe the upstream server's /v1/models until it returns an id or we time out.
    private static func discoverUpstreamID(port: Int, maxWait: Int) async throws -> String? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else { return nil }
        let deadline = Date().addingTimeInterval(TimeInterval(maxWait))
        while Date() < deadline {
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 2
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let arr = json["data"] as? [[String: Any]],
                   let first = arr.first,
                   let id = first["id"] as? String {
                    NSLog("[openhost] Gateway: discovered upstream id=%@ on :%d", id, port)
                    return id
                }
            } catch {
                // not ready yet
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        NSLog("[openhost] Gateway: timed out waiting for upstream :%d", port)
        return nil
    }

    private static func streamFromUpstream(request: URLRequest) async throws -> Response {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = response as? HTTPURLResponse
        let status = HTTPResponse.Status(code: http?.statusCode ?? 502)

        let streamBody = ResponseBody(asyncSequence: UpstreamByteSequence(bytes: bytes))
        var resp = Response(status: status, body: streamBody)
        resp.headers[.contentType] = http?.value(forHTTPHeaderField: "Content-Type") ?? "text/event-stream"
        resp.headers[.init("Cache-Control")!] = "no-cache"
        return resp
    }
}

/// Adapter: `URLSession.AsyncBytes` → `AsyncSequence<ByteBuffer>`
/// Rewrites each SSE `data:` event so that Qwen/MLX-specific `delta.reasoning`
/// is folded into standard `delta.content` (wrapped in `<think>…</think>`).
/// This lets any OpenAI-spec client (langchain, openai-python) surface the
/// reasoning stream instead of seeing empty deltas.
struct UpstreamByteSequence: AsyncSequence, Sendable {
    typealias Element = ByteBuffer
    let bytes: URLSession.AsyncBytes

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(lines: bytes.lines.makeAsyncIterator())
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        var lines: AsyncLineSequence<URLSession.AsyncBytes>.AsyncIterator
        var inReasoning = false
        var reasoningClosed = false

        mutating func next() async throws -> ByteBuffer? {
            guard let line = try await lines.next() else { return nil }
            let transformed = rewrite(line: line)
            var buf = ByteBuffer()
            buf.writeString(transformed)
            buf.writeString("\n\n")
            return buf
        }

        private mutating func rewrite(line: String) -> String {
            // Only rewrite SSE data lines with a JSON payload.
            guard line.hasPrefix("data:") else { return line }
            let payloadStart = line.index(line.startIndex, offsetBy: 5)
            let trimmed = line[payloadStart...].trimmingCharacters(in: .whitespaces)
            guard trimmed != "[DONE]",
                  let data = trimmed.data(using: .utf8),
                  var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return line }

            guard var choices = json["choices"] as? [[String: Any]],
                  !choices.isEmpty,
                  var delta = choices[0]["delta"] as? [String: Any]
            else { return line }

            let existingContent = delta["content"] as? String ?? ""
            let reasoning = delta["reasoning"] as? String
            var newContent = existingContent

            if let r = reasoning, !r.isEmpty {
                if !inReasoning {
                    newContent = "<think>" + r + newContent
                    inReasoning = true
                } else {
                    newContent = r + newContent
                }
                delta["reasoning"] = nil
            } else if inReasoning, !reasoningClosed {
                // Reasoning finished; emit a closing tag on the first non-reasoning chunk.
                newContent = "</think>" + newContent
                reasoningClosed = true
            }

            if newContent.isEmpty, existingContent.isEmpty { return line }
            delta["content"] = newContent
            choices[0]["delta"] = delta
            json["choices"] = choices

            guard let rewritten = try? JSONSerialization.data(withJSONObject: json),
                  let str = String(data: rewritten, encoding: .utf8)
            else { return line }
            return "data: " + str
        }
    }
}
