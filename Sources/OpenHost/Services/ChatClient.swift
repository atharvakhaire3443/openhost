import Foundation

struct ChatStreamEvent {
    var deltaText: String?
    var finished: Bool
    var usage: UsageInfo?
}

struct UsageInfo {
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
}

enum ChatClientError: Error, LocalizedError {
    case noActiveModel
    case badStatus(Int, String)
    case decodeFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noActiveModel: return "No model is running. Start one from the Models tab."
        case .badStatus(let code, let body):
            return "HTTP \(code): \(body.prefix(200))"
        case .decodeFailed: return "Could not decode streaming response."
        case .cancelled: return "Cancelled."
        }
    }
}

struct ChatClient {
    let endpoint: URL
    let apiModelName: String

    init(port: Int, apiModelName: String) {
        self.endpoint = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        self.apiModelName = apiModelName
    }

    static func serializeMessage(_ m: Message) -> [String: Any] {
        let textAttachments = m.attachments.filter { $0.kind == .text }
        let imageAttachments = m.attachments.filter { $0.kind == .image }

        var textBody = ""
        for a in textAttachments {
            textBody += "[Attached: \(a.filename)]\n```\n\(a.payload)\n```\n\n"
        }
        textBody += m.content

        if imageAttachments.isEmpty {
            return ["role": m.role.rawValue, "content": textBody]
        }

        var parts: [[String: Any]] = [["type": "text", "text": textBody]]
        for img in imageAttachments {
            parts.append([
                "type": "image_url",
                "image_url": ["url": img.payload]
            ])
        }
        return ["role": m.role.rawValue, "content": parts]
    }

    func stream(
        messages: [Message],
        settings: ChatSettings
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStream(messages: messages, settings: settings) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(
        messages: [Message],
        settings: ChatSettings,
        onEvent: @Sendable (ChatStreamEvent) -> Void
    ) async throws {
        var payloadMessages: [[String: Any]] = []
        if !settings.systemPrompt.isEmpty {
            payloadMessages.append(["role": "system", "content": settings.systemPrompt])
        }
        for m in messages where m.role != .system {
            payloadMessages.append(Self.serializeMessage(m))
        }

        var payload: [String: Any] = [
            "model": apiModelName,
            "messages": payloadMessages,
            "stream": true,
            "stream_options": ["include_usage": true],
            "temperature": settings.temperature,
            "top_p": settings.topP,
            "max_tokens": settings.maxTokens
        ]
        if settings.topK > 0 { payload["top_k"] = settings.topK }
        if settings.minP > 0 { payload["min_p"] = settings.minP }
        if settings.presencePenalty != 0 { payload["presence_penalty"] = settings.presencePenalty }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 600
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatClientError.decodeFailed }
        if !(200...299).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines { body += line + "\n"; if body.count > 500 { break } }
            throw ChatClientError.badStatus(http.statusCode, body)
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payloadText = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payloadText == "[DONE]" {
                onEvent(ChatStreamEvent(deltaText: nil, finished: true, usage: nil))
                return
            }
            guard let data = payloadText.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            var deltaText: String?
            if let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let delta = first["delta"] as? [String: Any],
               let content = delta["content"] as? String {
                deltaText = content
            }

            var usage: UsageInfo?
            if let u = json["usage"] as? [String: Any] {
                usage = UsageInfo(
                    promptTokens: u["prompt_tokens"] as? Int,
                    completionTokens: u["completion_tokens"] as? Int,
                    totalTokens: u["total_tokens"] as? Int
                )
            }

            if deltaText != nil || usage != nil {
                onEvent(ChatStreamEvent(deltaText: deltaText, finished: false, usage: usage))
            }
        }
        onEvent(ChatStreamEvent(deltaText: nil, finished: true, usage: nil))
    }
}
