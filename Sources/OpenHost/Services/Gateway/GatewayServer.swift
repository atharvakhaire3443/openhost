import Foundation
import Hummingbird
import HTTPTypes
import Logging

@MainActor
final class GatewayServer: ObservableObject {
    static let shared = GatewayServer()

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var port: Int = 8766
    @Published private(set) var lastError: String?

    private var serviceTask: Task<Void, Error>?

    private init() {}

    func start(port: Int = 8766) async throws {
        guard !isRunning else { return }
        self.port = port
        self.lastError = nil

        let router = Router()
        registerRoutes(on: router)

        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname("127.0.0.1", port: port),
                serverName: "OpenHost"
            ),
            logger: makeLogger()
        )

        let task = Task {
            try await app.runService()
        }
        serviceTask = task
        isRunning = true
        NSLog("[openhost] Gateway started on 127.0.0.1:\(port)")
    }

    func stop() async {
        guard isRunning else { return }
        serviceTask?.cancel()
        serviceTask = nil
        isRunning = false
        NSLog("[openhost] Gateway stopped")
    }

    private func makeLogger() -> Logger {
        var logger = Logger(label: "openhost.gateway")
        logger.logLevel = .info
        return logger
    }

    // MARK: - Routes

    private func registerRoutes(on router: Router<BasicRequestContext>) {
        router.get("/healthz") { _, _ in
            return Response(status: .ok, body: .init(byteBuffer: .init(string: #"{"ok":true}"#)))
        }

        router.get("/v1/models") { _, _ in
            return try await ModelsRoute.list()
        }

        router.post("/v1/models/:id/start") { req, context in
            let id = context.parameters.get("id") ?? ""
            return try await ModelsRoute.start(id: id)
        }

        router.post("/v1/models/:id/stop") { req, context in
            let id = context.parameters.get("id") ?? ""
            return try await ModelsRoute.stop(id: id)
        }

        router.post("/v1/chat/completions") { req, context in
            return try await ChatRoute.proxy(request: req, context: context)
        }

        router.post("/v1/search") { req, context in
            return try await SearchRoute.handle(request: req, context: context)
        }

        router.post("/v1/audio/transcriptions") { req, context in
            return try await TranscriptionRoute.handle(request: req, context: context)
        }
    }
}
