import Foundation

@MainActor
enum EntryPoint {
    static func run() {
        let args = CommandLine.arguments

        if args.contains("--headless") {
            runHeadless(port: parsePort(args) ?? 8766)
        } else {
            OpenHostApp.main()
        }
    }

    private static func parsePort(_ args: [String]) -> Int? {
        guard let idx = args.firstIndex(of: "--port"), idx + 1 < args.count else { return nil }
        return Int(args[idx + 1])
    }

    private static func runHeadless(port: Int) {
        FileHandle.standardError.write(
            "[openhost] Starting in headless mode on 127.0.0.1:\(port)\n".data(using: .utf8)!
        )
        Task {
            do {
                try await GatewayServer.shared.start(port: port)
            } catch {
                FileHandle.standardError.write(
                    "[openhost] Gateway failed to start: \(error.localizedDescription)\n".data(using: .utf8)!
                )
                exit(1)
            }
        }
        signal(SIGINT) { _ in
            FileHandle.standardError.write("\n[openhost] Shutting down\n".data(using: .utf8)!)
            exit(0)
        }
        RunLoop.main.run()
    }
}

EntryPoint.run()
