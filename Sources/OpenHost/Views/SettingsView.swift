import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var whisper = TranscriptionService.shared
    @StateObject private var gateway = GatewayServer.shared
    @State private var testOutput: String?
    @State private var testing: Bool = false
    @State private var devices: [AudioInputDevice] = []
    @State private var outputs: [AudioOutputDevice] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                gatewaySection
                searchSection
                transcriptionSection
                Spacer(minLength: 40)
            }
            .padding(.horizontal, 32).padding(.top, 28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            devices = AudioRecorder.enumerateDevices()
            outputs = AudioDevices.listOutputs()
        }
    }

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: "Transcription",
                subtitle: "Whisper runs locally on the Neural Engine. Mic features require running OpenHost.app — see scripts/make-app.sh."
            )
            HStack {
                Text("Model").frame(width: 120, alignment: .leading)
                Picker("", selection: $settings.whisperModel) {
                    ForEach(WhisperModelID.allCases) { m in Text(m.displayName).tag(m) }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
                Text("~\(settings.whisperModel.approxSizeMB) MB").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Input device").frame(width: 120, alignment: .leading)
                Picker("", selection: $settings.whisperDeviceID) {
                    ForEach(devices) { d in Text(d.name).tag(d.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
                Button("Refresh") {
                    devices = AudioRecorder.enumerateDevices()
                    outputs = AudioDevices.listOutputs()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            HStack {
                Text("Output device").frame(width: 120, alignment: .leading)
                Picker("", selection: $settings.whisperOutputDeviceID) {
                    ForEach(outputs) { d in Text(d.name).tag(d.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
            }
            HStack(spacing: 10) {
                Button {
                    Task { await whisper.ensureLoaded(model: settings.whisperModel) }
                } label: {
                    HStack(spacing: 6) {
                        if whisperBusy { ProgressView().controlSize(.small) }
                        Text(modelActionLabel)
                    }
                }
                .disabled(whisperBusy || (whisper.loadedModel == settings.whisperModel && whisper.status == .ready))
                Text(modelStatusLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }

    private var whisperBusy: Bool {
        switch whisper.status {
        case .downloading, .loading, .transcribing: return true
        default: return false
        }
    }
    private var modelActionLabel: String {
        if whisper.loadedModel == settings.whisperModel, whisper.status == .ready { return "Model ready" }
        switch whisper.status {
        case .downloading: return "Downloading…"
        case .loading: return "Loading…"
        default: return "Pre-download model"
        }
    }
    private var modelStatusLabel: String {
        switch whisper.status {
        case .idle: return "Model will download on first use."
        case .downloading: return "Fetching weights (~\(settings.whisperModel.approxSizeMB) MB)…"
        case .loading: return "Warming up Neural Engine…"
        case .ready: return whisper.loadedModel == settings.whisperModel ? "Loaded." : "Different model loaded."
        case .transcribing: return "Busy."
        case .error(let s): return "Error: \(s)"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings").font(.system(size: 22, weight: .semibold))
            Text("App-wide preferences. Per-chat settings live in the Chat sidebar.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var gatewaySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: "Python / Langchain Gateway",
                subtitle: "Exposes OpenHost as an OpenAI-compatible HTTP server on :\(gateway.port). Enable this to drive OpenHost from Python."
            )
            HStack {
                Toggle(isOn: Binding(
                    get: { gateway.isRunning },
                    set: { new in
                        Task {
                            if new {
                                try? await gateway.start()
                            } else {
                                await gateway.stop()
                            }
                        }
                    }
                )) {
                    Text(gateway.isRunning ? "Running on 127.0.0.1:\(gateway.port)" : "Off")
                        .font(.system(size: 12))
                }
                .toggleStyle(.switch)
                Spacer()
                if gateway.isRunning {
                    Circle().fill(.green).frame(width: 8, height: 8)
                }
            }
            if gateway.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PYTHON QUICKSTART")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(pythonSnippet)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(10)
                    }
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.05)))
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pythonSnippet, forType: .string)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if let err = gateway.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }

    private var pythonSnippet: String {
        """
        from langchain_openai import ChatOpenAI
        llm = ChatOpenAI(
            base_url="http://localhost:\(gateway.port)/v1",
            api_key="openhost",  # ignored, required by langchain
            model="qwen3.6-35b-mlx"
        )
        print(llm.invoke("Hello from OpenHost"))
        """
    }

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Web search", subtitle: "Used when the globe toggle is on in chat. Routes through the provider you pick.")

            HStack {
                Text("Provider").frame(width: 120, alignment: .leading)
                Picker("", selection: $settings.searchProvider) {
                    ForEach(SearchProviderKind.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }

            if settings.searchProvider == .tavily {
                keyField(
                    label: "Tavily API key",
                    binding: $settings.tavilyKey,
                    placeholder: "tvly-...",
                    hint: "Get a free key at tavily.com — 1,000 req/mo included."
                )
            }
            if settings.searchProvider == .brave {
                keyField(
                    label: "Brave API key",
                    binding: $settings.braveKey,
                    placeholder: "BSA...",
                    hint: "Sign up at brave.com/search/api."
                )
            }
            if settings.searchProvider == .searxng {
                keyField(
                    label: "SearXNG URL",
                    binding: $settings.searxngURL,
                    placeholder: "http://localhost:8888",
                    hint: "Point to your SearXNG instance. Format JSON must be enabled."
                )
            }
            if settings.searchProvider == .duckduckgo {
                Text("Keyless fallback via DuckDuckGo HTML. May break if DDG changes markup. Upgrade to Tavily or SearXNG for reliability.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Text("Max results").frame(width: 120, alignment: .leading)
                Stepper("\(settings.searchMaxResults)", value: $settings.searchMaxResults, in: 1...10)
                    .frame(width: 120, alignment: .leading)
            }

            HStack(spacing: 10) {
                Button {
                    runTest()
                } label: {
                    HStack(spacing: 6) {
                        if testing { ProgressView().controlSize(.small) }
                        Text("Test search")
                    }
                }
                .disabled(testing)
                if let out = testOutput {
                    Text(out)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(out.hasPrefix("✓") ? .green : .red)
                        .lineLimit(3)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }

    @ViewBuilder
    private func keyField(label: String, binding: Binding<String>, placeholder: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).frame(width: 120, alignment: .leading)
                SecureField(placeholder, text: binding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
            }
            Text(hint).font(.caption2).foregroundStyle(.secondary).padding(.leading, 120)
        }
    }

    private func runTest() {
        testing = true
        testOutput = nil
        let provider = SearchRouter.makeProvider(from: settings)
        let n = settings.searchMaxResults
        Task {
            do {
                let r = try await provider.search(query: "latest Swift version release", maxResults: n)
                await MainActor.run {
                    testOutput = "✓ \(r.count) results — top: \(r.first?.title.prefix(60) ?? "—")"
                    testing = false
                }
            } catch {
                await MainActor.run {
                    testOutput = "✗ \(error.localizedDescription)"
                    testing = false
                }
            }
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}
