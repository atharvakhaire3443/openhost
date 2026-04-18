import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TranscribeView: View {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var service = TranscriptionService.shared
    @StateObject private var recorder = AudioRecorder()
    @StateObject private var playback = AudioPlaybackEngine()
    @State private var devices: [AudioInputDevice] = []
    @State private var outputs: [AudioOutputDevice] = []
    @State private var transcript: TranscriptResult?
    @State private var playbackSource: PlaybackSource?
    @State private var isBusy: Bool = false
    @State private var error: String?
    @State private var liveMode: Bool = true
    @State private var liveTask: Task<Void, Never>?
    @State private var liveText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            controlStrip
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    recordingPane
                    if let err = error {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                    if playbackSource != nil {
                        playerPane
                    }
                    if let tr = transcript {
                        transcriptPane(tr)
                    } else if !recorder.isRecording {
                        emptyPane
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            devices = AudioRecorder.enumerateDevices()
            outputs = AudioDevices.listOutputs()
            if settings.whisperDeviceID.isEmpty { settings.whisperDeviceID = devices.first?.id ?? "" }
            if settings.whisperOutputDeviceID.isEmpty { settings.whisperOutputDeviceID = outputs.first?.id ?? "" }
            if !settings.whisperOutputDeviceID.isEmpty {
                playback.setOutputDevice(uid: settings.whisperOutputDeviceID)
            }
        }
        .onChange(of: settings.whisperOutputDeviceID) { _, new in
            if !new.isEmpty { playback.setOutputDevice(uid: new) }
        }
    }

    private var controlStrip: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "mic").foregroundStyle(.secondary)
                Picker("", selection: $settings.whisperDeviceID) {
                    ForEach(devices) { d in Text(d.name).tag(d.id) }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Picker("", selection: $settings.whisperOutputDeviceID) {
                    ForEach(outputs) { d in Text(d.name).tag(d.id) }
                }
                .labelsHidden()
                .frame(width: 160)
            }

            HStack(spacing: 6) {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                Picker("", selection: $settings.whisperModel) {
                    ForEach(WhisperModelID.allCases) { m in Text(m.displayName).tag(m) }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            statusPill

            Spacer()

            Button("Refresh") {
                devices = AudioRecorder.enumerateDevices()
                outputs = AudioDevices.listOutputs()
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var playerPane: some View {
        HStack(spacing: 12) {
            Button {
                if playback.isPlaying { playback.pause() } else { playback.play() }
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14))
                    .frame(width: 36, height: 28)
            }
            .buttonStyle(.borderedProminent)

            Text(timeString(playback.currentTime))
                .font(.system(size: 11, design: .monospaced))
                .frame(width: 56, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { min(playback.duration, playback.currentTime) },
                    set: { playback.seek(to: $0) }
                ),
                in: 0...(max(0.1, playback.duration))
            )

            Text(timeString(playback.duration))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15), lineWidth: 0.5))
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusLabel).font(.system(size: 11))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.1)))
    }

    private var statusColor: Color {
        switch service.status {
        case .idle: return .gray
        case .downloading, .loading: return .orange
        case .ready: return .green
        case .transcribing: return .blue
        case .error: return .red
        }
    }
    private var statusLabel: String {
        switch service.status {
        case .idle: return "whisper: idle"
        case .downloading: return "downloading model…"
        case .loading: return "loading model…"
        case .ready: return "ready"
        case .transcribing: return "transcribing…"
        case .error(let s): return "error: \(s.prefix(40))"
        }
    }

    private var recordingPane: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Button {
                    Task { await toggleRecord() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text(recorder.isRecording ? "Stop" : "Record")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .frame(width: 120)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? .red : .accentColor)
                .disabled(isBusy && !recorder.isRecording)

                Button {
                    pickAudioFile()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                        Text("Upload audio…").font(.system(size: 13))
                    }
                    .frame(width: 140)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .disabled(isBusy || recorder.isRecording)

                if recorder.isRecording {
                    Text(timeString(recorder.elapsed))
                        .font(.system(.title3, design: .monospaced))
                        .foregroundStyle(.red)
                    levelMeter
                } else if isBusy {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()

                Toggle(isOn: $liveMode) {
                    Label("Live", systemImage: "dot.radiowaves.left.and.right")
                        .font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Transcribe continuously while recording")
            }
            if recorder.isRecording && liveMode && !liveText.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "waveform.badge.mic")
                        .foregroundStyle(.red)
                        .font(.system(size: 12))
                    Text(liveText)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08)))
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }

    private var levelMeter: some View {
        let pct = CGFloat(min(1, max(0, recorder.level)))
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2)).frame(width: 180, height: 8)
            RoundedRectangle(cornerRadius: 4).fill(Color.red.opacity(0.7)).frame(width: max(2, 180 * pct), height: 8)
        }
    }

    private var emptyPane: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform.and.mic").font(.system(size: 36)).foregroundStyle(.tertiary)
            Text("Record mic or upload an audio file to get a transcript.")
                .font(.callout).foregroundStyle(.secondary)
            Text("First run with \(settings.whisperModel.displayName) will download ~\(settings.whisperModel.approxSizeMB) MB.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func transcriptPane(_ tr: TranscriptResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transcript").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(String(format: "took %.1fs · %@", tr.durationSec, tr.modelID))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tr.segments) { s in
                        Button {
                            playback.seek(to: TimeInterval(s.start))
                            if !playback.isPlaying { playback.play() }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Text(s.startFormatted)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(currentSegment(s) ? Color.accentColor : .secondary)
                                    .frame(width: 70, alignment: .leading)
                                Text(s.text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(currentSegment(s) ? Color.primary : Color.primary.opacity(0.85))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                            }
                            .padding(.vertical, 2).padding(.horizontal, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(currentSegment(s) ? Color.accentColor.opacity(0.10) : Color.clear)
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(s.id)
                    }
                    if tr.segments.isEmpty {
                        Text(tr.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .onChange(of: playback.currentTime) { _, _ in
                    guard playback.isPlaying,
                          let current = tr.segments.first(where: { currentSegment($0) }) else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(current.id, anchor: .center)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15), lineWidth: 0.5))

            HStack(spacing: 8) {
                Button("Copy") { copyText(tr.text) }
                Button("Export .txt") { export(tr, format: .txt) }
                Button("Export .srt") { export(tr, format: .srt) }
                Spacer()
                Button("Clear", role: .destructive) {
                    transcript = nil
                    playbackSource = nil
                    playback.stop()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Actions

    private func toggleRecord() async {
        error = nil
        if recorder.isRecording {
            liveTask?.cancel(); liveTask = nil
            let samples = recorder.stop()
            await transcribeSamples(samples)
            liveText = ""
        } else {
            do {
                try await recorder.start(preferredDeviceID: settings.whisperDeviceID)
                if liveMode {
                    await service.ensureLoaded(model: settings.whisperModel)
                    startLiveLoop()
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func startLiveLoop() {
        liveText = ""
        liveTask?.cancel()
        liveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return }
                let snap = await MainActor.run { recorder.samples }
                if snap.count < 8_000 { continue }
                do {
                    let tr = try await TranscriptionService.shared.transcribePartial(audioArray: snap)
                    await MainActor.run { self.liveText = tr.text }
                } catch {
                    // ignore partial errors
                }
            }
        }
    }

    private func transcribeSamples(_ samples: [Float]) async {
        guard !samples.isEmpty else {
            self.error = "No audio was captured. Check the input device and mic permission."
            return
        }
        isBusy = true
        defer { isBusy = false }
        await service.ensureLoaded(model: settings.whisperModel)
        do {
            let tr = try await service.transcribe(audioArray: samples)
            transcript = tr
            let source = PlaybackSource.samples(samples, sampleRate: 16000)
            playbackSource = source
            playback.load(source)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func currentSegment(_ s: TranscriptSegment) -> Bool {
        TimeInterval(s.start) <= playback.currentTime && playback.currentTime < TimeInterval(s.end)
    }

    private func pickAudioFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = [.audio]
        if let m4a = UTType(filenameExtension: "m4a") { types.append(m4a) }
        if let mp3 = UTType(filenameExtension: "mp3") { types.append(mp3) }
        if let wav = UTType(filenameExtension: "wav") { types.append(wav) }
        panel.allowedContentTypes = types
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                error = nil
                isBusy = true
                defer { isBusy = false }
                await service.ensureLoaded(model: settings.whisperModel)
                do {
                    let tr = try await service.transcribe(audioPath: url.path)
                    transcript = tr
                    let source = PlaybackSource.file(url)
                    playbackSource = source
                    playback.load(source)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private enum ExportFormat { case txt, srt }

    private func export(_ tr: TranscriptResult, format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "transcript.\(format == .txt ? "txt" : "srt")"
        panel.allowedContentTypes = [format == .txt ? .plainText : (UTType(filenameExtension: "srt") ?? .plainText)]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let body: String
        switch format {
        case .txt: body = tr.text
        case .srt: body = srt(from: tr)
        }
        try? body.data(using: .utf8)?.write(to: url)
    }

    private func srt(from tr: TranscriptResult) -> String {
        var out = ""
        for (i, s) in tr.segments.enumerated() {
            out += "\(i + 1)\n"
            out += "\(srtTime(s.start)) --> \(srtTime(s.end))\n"
            out += s.text + "\n\n"
        }
        return out
    }
    private func srtTime(_ t: Float) -> String {
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let ms = Int((t - Float(total)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private func copyText(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60, s = total % 60
        let ms = Int((t - Double(total)) * 10)
        return String(format: "%02d:%02d.%d", m, s, ms)
    }
}
