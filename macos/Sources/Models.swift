import Foundation

struct SetupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ModelPair: Codable, Equatable {
    var thinkingModel: String
    var codingModel: String
    var unique: [String] { thinkingModel == codingModel ? [thinkingModel] : [thinkingModel, codingModel] }

    static func recommended(memoryGiB: Int) -> Self {
        let pair: (String, String)
        switch memoryGiB {
        case ..<16: pair = ("hermes3:3b", "")
        case 16..<24: pair = ("qwen3.5:4b", "qwen3.5:4b")
        case 24..<32: pair = ("qwen3.5:9b", "qwen3.5:9b")
        case 32..<96: pair = ("hermes3:8b", "qwen3-coder:30b")
        case 96..<128: pair = ("hermes3:8b", "qwen3-coder-next:q4_K_M")
        default: pair = ("hermes3:8b", "qwen3-coder-next:q8_0")
        }
        return Self(thinkingModel: pair.0, codingModel: pair.1)
    }

    static let sizes: [String: Double] = ["hermes3:3b": 2, "hermes3:8b": 4.7, "qwen3.5:4b": 4,
        "qwen3.5:9b": 7.6, "qwen3-coder:30b": 19, "qwen3-coder-next:q4_K_M": 52, "qwen3-coder-next:q8_0": 85]

    func normalized() throws -> Self {
        func tag(_ input: String) throws -> String {
            let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/:@-]{0,254}$"#, options: .regularExpression) != nil
            else { throw SetupError("Enter an Ollama model name for each role.") }
            return s.split(separator: "/").last?.contains(":") == true || s.contains("@") ? s : s + ":latest"
        }
        return try Self(thinkingModel: tag(thinkingModel), codingModel: tag(codingModel))
    }

    func missing(from installed: Set<String>) -> [String] { unique.filter { !installed.contains($0) } }
}

struct InstalledModel: Decodable { let name: String }
struct Catalog: Decodable { let models: [InstalledModel] }
struct ModelSettings: Decodable {
    let status: String
    let models: [InstalledModel]
    let defaults: ModelPair
    let setupCompleted: Bool
    let error: String?
}
struct Pull: Decodable {
    let id, model, message, error: String?
    let status: String
    let completed, total: Int64?
}

struct LocalAPI {
    let base: URL
    var session: URLSession = .shared

    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: String]? = nil, timeout: Double = 20) async throws -> T {
        var req = URLRequest(url: base.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        if let body {
            req.httpBody = try JSONEncoder().encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SetupError("Local service: " + String(decoding: data.prefix(400), as: UTF8.self))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func isOpenMission() async -> Bool {
        struct Health: Decodable { let service, status: String }
        let value: Health? = try? await request("api/health", timeout: 3)
        return value?.service == "openmission-api" && value?.status == "ok"
    }

    func configure(_ pair: ModelPair, progress: (String) async -> Void) async throws {
        let settingsPath = "api/settings/models"
        for model in pair.unique {
            let settings: ModelSettings = try await request(settingsPath)
            guard settings.status == "ready" else { throw SetupError(settings.error ?? "OM cannot reach Ollama.") }
            if settings.models.contains(where: { $0.name == model }) { continue }
            let path = settingsPath + "/pull"
            var pull: Pull = try await request(path)
            if ["queued", "running"].contains(pull.status) {
                guard pull.model == model else { throw SetupError("Another model is downloading. Retry when it finishes.") }
            } else {
                pull = try await request(path, method: "POST", body: ["model": model])
            }
            let id = pull.id
            while ["queued", "running"].contains(pull.status) {
                let detail: String
                if let total = pull.total, total > 0, let done = pull.completed {
                    detail = "Layer \(Int(100 * Double(done) / Double(total)))%"
                } else { detail = pull.message ?? "Waiting for Ollama" }
                await progress("\(model) · \(detail)")
                try await Task.sleep(for: .seconds(1))
                pull = try await request(path)
                guard pull.id == id else { throw SetupError("Model download changed. Retry to check installed models.") }
            }
            guard pull.status == "succeeded" else { throw SetupError(pull.error ?? "Model download failed.") }
        }
        let saved: ModelSettings = try await request(settingsPath, method: "PUT",
            body: ["thinkingModel": pair.thinkingModel, "codingModel": pair.codingModel])
        guard saved.setupCompleted && saved.defaults == pair else { throw SetupError("OM could not confirm the model settings.") }
    }
}
