import Foundation
import WhisperKit

enum WhisperModelID: String, CaseIterable, Identifiable, Codable {
    case turbo = "openai_whisper-large-v3-v20240930_turbo_632MB"
    case largeV3 = "openai_whisper-large-v3-v20240930_626MB"
    case distil = "distil-whisper_distil-large-v3_turbo_600MB"
    case base = "openai_whisper-base"
    case tiny = "openai_whisper-tiny"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .turbo: return "large-v3 turbo (recommended)"
        case .largeV3: return "large-v3 (best quality)"
        case .distil: return "distil-large-v3 turbo (English, fastest)"
        case .base: return "base (lightweight)"
        case .tiny: return "tiny (instant)"
        }
    }

    var approxSizeMB: Int {
        switch self {
        case .turbo: return 632
        case .largeV3: return 626
        case .distil: return 600
        case .base: return 145
        case .tiny: return 75
        }
    }
}

struct TranscriptSegment: Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    let start: Float
    let end: Float
    let text: String

    var startFormatted: String { Self.format(start) }

    static func format(_ secs: Float) -> String {
        let s = Int(secs)
        let h = s / 3600, m = (s % 3600) / 60, rem = s % 60
        let ms = Int((secs - Float(s)) * 1000)
        if h > 0 { return String(format: "%d:%02d:%02d.%03d", h, m, rem, ms) }
        return String(format: "%02d:%02d.%03d", m, rem, ms)
    }
}

struct TranscriptResult: Equatable {
    let text: String
    let segments: [TranscriptSegment]
    let durationSec: Double
    let modelID: String
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "Whisper model not loaded yet."
        case .transcriptionFailed(let s): return "Transcription failed: \(s)"
        }
    }
}

struct WhisperKitBox: @unchecked Sendable {
    let kit: WhisperKit
}

@MainActor
final class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()

    @Published private(set) var status: Status = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var loadedModel: WhisperModelID?

    enum Status: Equatable {
        case idle
        case downloading
        case loading
        case ready
        case transcribing
        case error(String)
    }

    private var kitBox: WhisperKitBox?
    private var loadTask: Task<Void, Error>?

    private init() {}

    func ensureLoaded(model: WhisperModelID) async {
        if loadedModel == model, status == .ready { return }
        if let t = loadTask { _ = try? await t.value; if loadedModel == model { return } }

        let task = Task { [weak self] in
            guard let self else { return }
            self.status = .downloading
            self.progress = 0
            do {
                let config = WhisperKitConfig(
                    model: model.rawValue,
                    verbose: true,
                    logLevel: .info,
                    prewarm: true,
                    load: true,
                    download: true
                )
                self.status = .loading
                let kit = try await WhisperKit(config)
                self.kitBox = WhisperKitBox(kit: kit)
                self.loadedModel = model
                self.status = .ready
            } catch {
                self.status = .error(error.localizedDescription)
                throw error
            }
        }
        loadTask = task
        _ = try? await task.value
        loadTask = nil
    }

    func transcribe(audioArray: [Float]) async throws -> TranscriptResult {
        guard let box = kitBox else { throw TranscriptionError.modelNotLoaded }
        status = .transcribing
        defer { status = .ready }
        let started = Date()
        do {
            let results = try await box.kit.transcribe(audioArray: audioArray)
            return assemble(results: results, started: started)
        } catch {
            status = .error(error.localizedDescription)
            throw TranscriptionError.transcriptionFailed(error.localizedDescription)
        }
    }

    func transcribePartial(audioArray: [Float]) async throws -> TranscriptResult {
        guard let box = kitBox else { throw TranscriptionError.modelNotLoaded }
        let started = Date()
        let results = try await box.kit.transcribe(audioArray: audioArray)
        return assemble(results: results, started: started)
    }

    func transcribe(audioPath: String) async throws -> TranscriptResult {
        guard let box = kitBox else { throw TranscriptionError.modelNotLoaded }
        status = .transcribing
        defer { status = .ready }
        let started = Date()
        do {
            let results = try await box.kit.transcribe(audioPath: audioPath)
            return assemble(results: results, started: started)
        } catch {
            status = .error(error.localizedDescription)
            throw TranscriptionError.transcriptionFailed(error.localizedDescription)
        }
    }

    private func assemble(results: [TranscriptionResult], started: Date) -> TranscriptResult {
        var allSegments: [TranscriptSegment] = []
        var joinedText = ""
        for r in results {
            joinedText += r.text
            for s in r.segments {
                allSegments.append(TranscriptSegment(
                    start: Float(s.start),
                    end: Float(s.end),
                    text: s.text.trimmingCharacters(in: .whitespaces)
                ))
            }
        }
        return TranscriptResult(
            text: joinedText.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: allSegments,
            durationSec: Date().timeIntervalSince(started),
            modelID: loadedModel?.rawValue ?? "unknown"
        )
    }
}
