import SwiftUI

struct DetailView: View {
    @ObservedObject var runtime: ModelRuntime
    @EnvironmentObject var registry: ModelRegistry
    @State private var now = Date()
    @State private var bottomPane: BottomPane = .logs
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    enum BottomPane: String, CaseIterable { case logs = "Logs", slots = "Slots" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            stats
            Divider()
            if runtime.definition.backend == .llamaCpp && runtime.state == .running {
                Picker("", selection: $bottomPane) {
                    ForEach(BottomPane.allCases, id: \.self) { p in Text(p.rawValue).tag(p) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 20).padding(.top, 10)
            }
            if runtime.definition.backend == .llamaCpp && runtime.state == .running && bottomPane == .slots {
                SlotsView(port: runtime.definition.port)
            } else {
                LogView(lines: runtime.logs.items)
            }
        }
        .onReceive(timer) { now = $0 }
        .onChange(of: runtime.state) { _, new in
            if new != .running { bottomPane = .logs }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            StatusDot(state: runtime.state, reachable: runtime.isReachable)
                .scaleEffect(1.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(runtime.definition.displayName)
                    .font(.title3.weight(.semibold))
                Text("\(runtime.definition.backend.rawValue)  ·  localhost:\(runtime.definition.port)  ·  ~\(runtime.definition.approxMemoryGB) GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            controlButtons
        }
        .padding(20)
    }

    private var controlButtons: some View {
        HStack(spacing: 8) {
            if runtime.state.isActive {
                Button {
                    Task { await runtime.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    Task { await registry.start(runtime) }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
    }

    private var stats: some View {
        HStack(spacing: 28) {
            StatBlock(label: "State", value: runtime.state.label)
            StatBlock(label: "Health", value: runtime.isReachable ? "OK" : "—")
            StatBlock(label: "Uptime", value: uptimeString)
            StatBlock(label: "Port", value: ":\(runtime.definition.port)")
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var uptimeString: String {
        guard let started = runtime.startedAt, runtime.state == .running else { return "—" }
        let s = Int(now.timeIntervalSince(started))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

struct StatBlock: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .monospaced))
        }
    }
}
