import Foundation

final class ProcessSupervisor: @unchecked Sendable {
    private let launcherPath: String
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    var onOutput: (@Sendable (String) -> Void)?
    var onExit: (@Sendable (Int32) -> Void)?

    init(launcherPath: String) {
        self.launcherPath = launcherPath
    }

    func start() throws {
        guard FileManager.default.isExecutableFile(atPath: launcherPath) else {
            throw NSError(
                domain: "OpenHost",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Launcher not executable: \(launcherPath)"]
            )
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", launcherPath]

        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/bin"
        ].joined(separator: ":")
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":" + extra
        p.environment = env

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            if let s = String(data: data, encoding: .utf8) {
                s.split(whereSeparator: \.isNewline).forEach {
                    self?.onOutput?(String($0))
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            if let s = String(data: data, encoding: .utf8) {
                s.split(whereSeparator: \.isNewline).forEach {
                    self?.onOutput?(String($0))
                }
            }
        }

        p.terminationHandler = { [weak self] proc in
            self?.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            self?.stderrPipe?.fileHandleForReading.readabilityHandler = nil
            self?.onExit?(proc.terminationStatus)
        }

        try p.run()
        self.process = p
        self.stdoutPipe = out
        self.stderrPipe = err
    }

    func stop() async {
        guard let p = process, p.isRunning else { return }
        p.terminate()
        for _ in 0..<50 {
            if !p.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
        }
        process = nil
    }
}
