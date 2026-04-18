import Foundation
import Hummingbird
import HTTPTypes

enum TranscriptionRoute {
    /// OpenAI-compatible POST /v1/audio/transcriptions.
    /// Accepts multipart/form-data with a `file` field. Optional `response_format` field.
    static func handle(request: Request, context: BasicRequestContext) async throws -> Response {
        guard let ctype = request.headers[.contentType],
              let boundary = Multipart.boundary(fromContentType: ctype)
        else {
            return try jsonResponse([
                "error": "Content-Type must be multipart/form-data with a boundary"
            ], status: .badRequest)
        }

        // Accept up to 200 MB of audio.
        let body = try await request.body.collect(upTo: 200 * 1024 * 1024)
        let bodyBytes = body.getBytes(at: 0, length: body.readableBytes) ?? []
        let data = Data(bodyBytes)

        let parts = Multipart.parse(data: data, boundary: boundary)
        guard let filePart = parts.first(where: { $0.filename != nil }) else {
            return try jsonResponse(["error": "missing file part"], status: .badRequest)
        }

        let responseFormat = parts
            .first { $0.name == "response_format" }
            .flatMap { String(data: $0.body, encoding: .utf8) } ?? "json"

        // Write audio to a temp file so WhisperKit can read it with its own loader.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("openhost-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension(for: filePart.filename ?? "audio.wav"))
        try filePart.body.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = await MainActor.run { AppSettings.shared.whisperModel }
        await TranscriptionService.shared.ensureLoaded(model: model)

        do {
            let result = try await TranscriptionService.shared.transcribe(audioPath: tmp.path)
            switch responseFormat.lowercased() {
            case "text":
                var buf = ByteBuffer()
                buf.writeString(result.text)
                var resp = Response(status: .ok, body: .init(byteBuffer: buf))
                resp.headers[.contentType] = "text/plain; charset=utf-8"
                return resp
            case "srt":
                var buf = ByteBuffer()
                buf.writeString(renderSRT(result))
                var resp = Response(status: .ok, body: .init(byteBuffer: buf))
                resp.headers[.contentType] = "application/x-subrip"
                return resp
            case "verbose_json":
                return try jsonResponse([
                    "task": "transcribe",
                    "language": "en",
                    "duration": result.durationSec,
                    "text": result.text,
                    "model": result.modelID,
                    "segments": result.segments.map {
                        [
                            "start": Double($0.start),
                            "end": Double($0.end),
                            "text": $0.text
                        ]
                    }
                ])
            default: // "json"
                return try jsonResponse(["text": result.text])
            }
        } catch {
            return try jsonResponse([
                "error": "transcription failed: \(error.localizedDescription)"
            ], status: .internalServerError)
        }
    }

    private static func pathExtension(for filename: String) -> String {
        let pe = (filename as NSString).pathExtension
        return pe.isEmpty ? "wav" : pe
    }

    private static func renderSRT(_ r: TranscriptResult) -> String {
        var out = ""
        for (i, s) in r.segments.enumerated() {
            out += "\(i + 1)\n"
            out += "\(srtTime(s.start)) --> \(srtTime(s.end))\n"
            out += s.text + "\n\n"
        }
        return out
    }
    private static func srtTime(_ t: Float) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let ms = Int((t - Float(total)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
