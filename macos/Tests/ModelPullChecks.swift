import Foundation

// Scripted responses exercise the same OM API requests the app sends to localhost.
private final class ScriptedAPI: URLProtocol {
    struct Step {
        let method, path, json: String
        init(_ method: String, _ path: String, _ json: String) {
            self.method = method
            self.path = path
            self.json = json
        }
    }
    static var steps: [Step] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let step = Self.steps.removeFirst()
        let url = request.url!
        precondition(request.httpMethod == step.method && url.path == step.path)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(step.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func verifyModelPulls() async throws {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ScriptedAPI.self]
    let session = URLSession(configuration: config)
    defer { session.finishTasksAndInvalidate() }
    let api = LocalAPI(base: URL(string: "http://localhost")!, session: session)
    let pair = ModelPair.recommended(memoryGiB: 16)
    let path = "/api/settings/models", pull = path + "/pull"
    let settings = #"{"status":"ready","models":[],"defaults":{"thinkingModel":"","codingModel":""},"setupCompleted":false}"#
    let saved = #"{"status":"ready","models":[{"name":"qwen3.5:4b"}],"defaults":{"thinkingModel":"qwen3.5:4b","codingModel":"qwen3.5:4b"},"setupCompleted":true}"#
    let idle = #"{"status":"idle"}"#
    let running = #"{"id":"p","status":"running","model":"qwen3.5:4b"}"#
    let done = #"{"id":"p","status":"succeeded","model":"qwen3.5:4b"}"#
    let failed = #"{"id":"p","status":"failed","error":"disk full"}"#

    typealias Step = ScriptedAPI.Step
    let read = Step("GET", path, settings), save = Step("PUT", path, saved)
    func check(_ steps: [Step], expectedError: String? = nil) async throws {
        ScriptedAPI.steps = steps
        var failure: String?
        do { try await api.configure(pair) { _ in } }
        catch { failure = error.localizedDescription }
        precondition(failure == expectedError && ScriptedAPI.steps.isEmpty)
    }
    try await check([read, Step("GET", pull, idle), Step("POST", pull, running), Step("GET", pull, done), save])
    try await check([read, Step("GET", pull, running), Step("GET", pull, done), save])
    try await check([Step("GET", path, saved), save])
    try await check([read, Step("GET", pull, idle), Step("POST", pull, failed)], expectedError: "disk full")
    try await check([read, Step("GET", pull, running), Step("GET", pull, #"{"id":"other","status":"running"}"#)],
                    expectedError: "Model download changed. Retry to check installed models.")
}
