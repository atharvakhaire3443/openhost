import SwiftUI

struct SlotInfo: Identifiable, Equatable {
    let id: Int
    let state: String
    let nCtx: Int?
    let nPast: Int?
    let nPrompt: Int?
    let nDecoded: Int?
    let task: String?
}

struct SlotsView: View {
    let port: Int
    @State private var slots: [SlotInfo] = []
    @State private var lastError: String?
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("SLOTS").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 6)

            if let err = lastError {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal, 20).padding(.bottom, 8)
            }

            if slots.isEmpty {
                Text("No slots available. Available on llama.cpp servers.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.bottom, 14)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(slots) { s in slotRow(s) }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 14)
                }
            }
        }
        .background(Color.black.opacity(0.04))
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    @ViewBuilder
    private func slotRow(_ s: SlotInfo) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(s.state.lowercased().contains("idle") ? Color.gray.opacity(0.4) : Color.green)
                .frame(width: 8, height: 8)
            Text("#\(s.id)").font(.system(size: 11, weight: .semibold, design: .monospaced))
            Text(s.state).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            if let ctx = s.nCtx, let past = s.nPast {
                kvBar(past: past, ctx: ctx)
            } else if let ctx = s.nCtx {
                Text("ctx \(ctx)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            if let decoded = s.nDecoded {
                Text("\(decoded) tok").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.05)))
    }

    @ViewBuilder
    private func kvBar(past: Int, ctx: Int) -> some View {
        let pct = min(1.0, Double(past) / Double(max(1, ctx)))
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.2)).frame(width: 90, height: 5)
                RoundedRectangle(cornerRadius: 2).fill(pct > 0.85 ? Color.orange : Color.accentColor)
                    .frame(width: max(3, 90 * pct), height: 5)
            }
            Text("\(past)/\(ctx)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func startPolling() {
        Task { await refresh() }
        let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in await refresh() }
        }
        timer = t
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() async {
        guard let url = URL(string: "http://127.0.0.1:\(port)/slots") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                lastError = "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"
                return
            }
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                lastError = "Unexpected /slots response"
                return
            }
            let parsed = arr.map { d -> SlotInfo in
                SlotInfo(
                    id: d["id"] as? Int ?? -1,
                    state: stateString(from: d),
                    nCtx: d["n_ctx"] as? Int,
                    nPast: d["n_past"] as? Int,
                    nPrompt: d["n_prompt_tokens"] as? Int,
                    nDecoded: d["n_decoded"] as? Int,
                    task: d["task_id"].flatMap { "\($0)" }
                )
            }
            slots = parsed.sorted { $0.id < $1.id }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func stateString(from d: [String: Any]) -> String {
        if let s = d["state"] as? String { return s }
        if let i = d["state"] as? Int {
            return ["idle", "processing", "idle_embd", "done_prompt"].indices.contains(i)
                ? ["idle", "processing", "idle_embd", "done_prompt"][i]
                : "state=\(i)"
        }
        if let p = d["is_processing"] as? Bool { return p ? "processing" : "idle" }
        return "unknown"
    }
}
