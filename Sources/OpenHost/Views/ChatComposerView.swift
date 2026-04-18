import SwiftUI
import UniformTypeIdentifiers

struct ChatComposerView: View {
    @Binding var text: String
    @Binding var pendingAttachments: [MessageAttachment]
    @Binding var attachmentError: String?
    @Binding var webSearchEnabled: Bool
    let isStreaming: Bool
    let imagesAllowed: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    let onRegenerate: () -> Void
    let canRegenerate: Bool

    @State private var isTargeted: Bool = false
    @StateObject private var recorder = AudioRecorder()
    @State private var dictating: Bool = false
    @State private var dictationError: String?

    var body: some View {
        VStack(spacing: 0) {
            if !pendingAttachments.isEmpty || attachmentError != nil {
                attachmentRow
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    pickFiles()
                } label: {
                    Image(systemName: "paperclip")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.bordered)
                .help(imagesAllowed ? "Attach text, code, PDF, or image" : "Attach text, code, or PDF (image attach needs llama.cpp model)")

                Button {
                    webSearchEnabled.toggle()
                } label: {
                    Image(systemName: "globe")
                        .frame(width: 32, height: 32)
                        .foregroundStyle(webSearchEnabled ? Color.white : Color.primary)
                }
                .buttonStyle(.bordered)
                .tint(webSearchEnabled ? Color.accentColor : Color.secondary.opacity(0.4))
                .help(webSearchEnabled ? "Web search on — click to disable" : "Enable web search for this chat")

                Button {
                    Task { await toggleDictation() }
                } label: {
                    Image(systemName: recorder.isRecording ? "stop.fill" : (dictating ? "hourglass" : "mic.fill"))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(recorder.isRecording ? Color.white : Color.primary)
                }
                .buttonStyle(.bordered)
                .tint(recorder.isRecording ? Color.red : Color.secondary.opacity(0.4))
                .disabled(dictating && !recorder.isRecording)
                .help(recorder.isRecording ? "Stop dictation" : "Dictate — voice to text")

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 44, maxHeight: 160)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                        .onSubmit { onSend() }
                    if text.isEmpty {
                        Text("Type a message…   (⌘↩ send, ⇧↩ newline, drop files to attach)")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 14).padding(.top, 16)
                            .allowsHitTesting(false)
                    }
                }

                VStack(spacing: 6) {
                    if isStreaming {
                        Button(action: onStop) {
                            Image(systemName: "stop.fill").frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderedProminent).tint(.red).help("Stop")
                    } else {
                        Button(action: onSend) {
                            Image(systemName: "arrow.up").frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingAttachments.isEmpty)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Send (⌘↩)")
                    }
                    if canRegenerate && !isStreaming {
                        Button(action: onRegenerate) {
                            Image(systemName: "arrow.clockwise").frame(width: 32, height: 22)
                        }
                        .buttonStyle(.bordered).help("Regenerate")
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(.regularMaterial)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    private var attachmentRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let err = attachmentError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(pendingAttachments) { a in
                        AttachmentChipView(attachment: a, onRemove: {
                            pendingAttachments.removeAll { $0.id == a.id }
                        })
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 2)
    }

    private func pickFiles() {
        let urls = DocumentExtractor.pickFiles(imagesAllowed: imagesAllowed)
        ingest(urls: urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let box = URLBox()
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { obj, _ in
                if let u = obj { box.append(u) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            self.ingest(urls: box.all())
        }
    }

    private func ingest(urls: [URL]) {
        attachmentError = nil
        var firstError: String?
        for url in urls {
            do {
                let att = try DocumentExtractor.extract(url: url)
                if att.kind == .image && !imagesAllowed {
                    firstError = "Image attach requires the llama.cpp (uncensored) model — switch in the Models tab."
                    continue
                }
                pendingAttachments.append(att)
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        if let e = firstError { attachmentError = e }
    }

    private func toggleDictation() async {
        dictationError = nil
        if recorder.isRecording {
            let samples = recorder.stop()
            dictating = true
            defer { dictating = false }
            let settings = AppSettings.shared
            await TranscriptionService.shared.ensureLoaded(model: settings.whisperModel)
            do {
                let tr = try await TranscriptionService.shared.transcribe(audioArray: samples)
                let insert = tr.text
                if !insert.isEmpty {
                    if text.isEmpty { text = insert }
                    else { text += (text.hasSuffix(" ") ? "" : " ") + insert }
                }
            } catch {
                dictationError = error.localizedDescription
            }
        } else {
            do {
                try await recorder.start(preferredDeviceID: AppSettings.shared.whisperDeviceID)
            } catch {
                dictationError = error.localizedDescription
            }
        }
    }
}

private final class URLBox: @unchecked Sendable {
    private var urls: [URL] = []
    private let lock = NSLock()
    func append(_ u: URL) { lock.lock(); urls.append(u); lock.unlock() }
    func all() -> [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}
