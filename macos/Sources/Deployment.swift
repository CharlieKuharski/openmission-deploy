import Foundation
import AppKit
import Darwin

struct LocalDocker {
    let executable: URL

    static func locate() -> Self? {
        var candidates: [URL] = []
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.docker.docker") {
            candidates.append(app.appendingPathComponent("Contents/Resources/bin/docker"))
        }
        candidates += ["/Applications/Docker.app/Contents/Resources/bin/docker", NSHomeDirectory() + "/.docker/bin/docker",
                       "/usr/local/bin/docker", "/opt/homebrew/bin/docker"].map(URL.init(fileURLWithPath:))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }.map(Self.init)
    }

    func run(_ args: [String], at directory: URL? = nil, env: [String: String] = [:], timeout: Double = 20,
             update: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process(), pipe = Pipe()
            process.executableURL = executable
            process.arguments = args
            process.currentDirectoryURL = directory
            var vars = ["HOME": NSHomeDirectory(), "PATH": executable.deletingLastPathComponent().path + ":/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                        "LANG": "en_US.UTF-8", "COMPOSE_ANSI": "never"]
            if let directory { vars["PWD"] = directory.path }
            process.environment = vars.merging(env) { _, new in new }
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
            defer { stop.cancel() }
            var output = Data(), last = Date.distantPast
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                output.append(chunk)
                if output.count > 256_000 { output.removeFirst(output.count - 256_000) }
                if let update, Date().timeIntervalSince(last) >= 0.4,
                   let line = String(decoding: chunk, as: UTF8.self).split(whereSeparator: \.isNewline).last {
                    update(String(line.suffix(180)))
                    last = Date()
                }
            }
            process.waitUntilExit()
            let message = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw SetupError(message.isEmpty ? "Docker did not finish. Check Docker Desktop and retry." : String(message.suffix(1400)))
            }
            return message
        }.value
    }

    func requireLocalEngine() async throws {
        let endpoint = try await run(["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"])
        guard endpoint.hasPrefix("unix://") else { throw SetupError("Select a local Docker context in Docker Desktop.") }
        _ = try await run(["info", "--format", "{{.ServerVersion}}"])
        _ = try await run(["compose", "version", "--short"])
    }

    struct Stack {
        let name, service, state, container, directory, image: String
    }
    func stacks() async throws -> [Stack] {
        let format = #"{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.service"}}|{{.State}}|{{.ID}}|{{.Label "com.docker.compose.project.working_dir"}}|{{.Image}}"#
        let list = try await run(["ps", "-a", "--filter", "label=com.docker.compose.project", "--format", format])
        return list.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.components(separatedBy: "|")
            guard f.count == 6 else { return nil }
            return Stack(name: f[0], service: f[1], state: f[2], container: f[3], directory: f[4], image: f[5])
        }
    }

    func installations(managedName: String) async throws -> [Stack] {
        let containers = try await stacks()
        let names = Set(containers.filter { item in
            let repository = item.image.split(separator: "@").first?.split(separator: "/").last?.split(separator: ":").first
            return item.name == managedName || item.name == "openmission" || (item.service == "api" && repository == "openmission")
        }.map(\.name))
        return containers.filter { names.contains($0.name) }.sorted { lhs, rhs in
            func rank(_ name: String) -> Int { name == managedName ? 0 : name == "openmission" ? 1 : 2 }
            return (rank(lhs.name), lhs.name) < (rank(rhs.name), rhs.name)
        }
    }

    func verifiedUI(_ stack: Stack) async -> URL? {
        guard stack.service == "ui", stack.state == "running",
              let ports = try? await run(["port", stack.container]) else { return nil }
        for line in ports.components(separatedBy: .newlines) {
            guard let host = line.components(separatedBy: " -> ").last,
                  let port = Int(host.components(separatedBy: ":").last ?? ""),
                  let url = URL(string: "http://127.0.0.1:\(port)"), await LocalAPI(base: url).isOpenMission(),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("<title>OpenMission") else { continue }
            return url
        }
        return nil
    }
}

struct Deployment {
    let root, resources: URL
    var name = "openmission-mac"
    var ports = [15173, 18080, 18642, 19119]
    var ui: URL { URL(string: "http://127.0.0.1:\(ports[0])")! }
    var pending: URL { root.appendingPathComponent("model-selection.json") }
    private var fm: FileManager { .default }

    func choice() throws -> ModelPair? {
        guard fm.fileExists(atPath: pending.path) else { return nil }
        return try JSONDecoder().decode(ModelPair.self, from: Data(contentsOf: pending))
    }

    func initialize(_ pair: ModelPair) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dotEnv = root.appendingPathComponent(".env")
        if !fm.fileExists(atPath: dotEnv.path) {
            var lines = try String(contentsOf: resources.appendingPathComponent("release.env"), encoding: .utf8)
                .components(separatedBy: .newlines)
            let secretKeys = ["HERMES_API_KEY", "BROWSERLESS_TOKEN", "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD"]
            for i in lines.indices {
                let key = String(lines[i].prefix { $0 != "=" })
                if secretKeys.contains(key) { lines[i] = key + "=" + UUID().uuidString + UUID().uuidString }
                if key == "OPENMISSION_CHAT_MODEL" { lines[i] = key + "=" + pair.thinkingModel }
                if ["OPENMISSION_CODE_GEN_MODEL", "OPENMISSION_OLLAMA_MODEL"].contains(key) { lines[i] = key + "=" + pair.codingModel }
            }
            try Data(lines.joined(separator: "\n").utf8).write(to: dotEnv, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dotEnv.path)
        }
        for sub in ["workspace", "data", "searxng"] {
            try fm.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        for file in ["compose.yaml", "searxng/settings.yml"] {
            let target = root.appendingPathComponent(file)
            if !fm.fileExists(atPath: target.path) {
                try Data(contentsOf: resources.appendingPathComponent(file)).write(to: target, options: .atomic)
            }
        }
        try JSONEncoder().encode(pair).write(to: pending, options: .atomic)
    }

    func finish() throws { if fm.fileExists(atPath: pending.path) { try fm.removeItem(at: pending) } }

    func compose(_ docker: LocalDocker, _ args: [String], update: (@Sendable (String) -> Void)? = nil) async throws {
        let keys = ["OPENMISSION_UI_PORT", "OPENMISSION_API_PORT", "HERMES_GATEWAY_PORT", "HERMES_DASHBOARD_PORT"]
        var env = Dictionary(uniqueKeysWithValues: zip(keys, ports.map(String.init)))
        env["COMPOSE_PROJECT_NAME"] = name
        env["OPENMISSION_HOST_WORKSPACE_ROOT"] = root.appendingPathComponent("workspace").path
        env["OPENMISSION_DATA_ROOT"] = root.appendingPathComponent("data").path
        _ = try await docker.run(["compose", "-p", name, "--env-file", ".env", "-f", "compose.yaml"] + args,
                                 at: root, env: env, timeout: 3600, update: update)
    }

    func start(_ docker: LocalDocker, progress: @escaping @Sendable (String) -> Void) async throws {
        let prepared = root.appendingPathComponent(".runtime-prepared")
        if !fm.fileExists(atPath: prepared.path) {
            let existing = try await docker.stacks()
            guard !existing.contains(where: { $0.name == name && $0.state == "running" }) else {
                throw SetupError("The installation has running services. Stop its workspace writers before preparing storage.")
            }
            progress("Downloading the release images…")
            try await compose(docker, ["pull"], update: progress)
            progress("Preparing project storage…")
            try await compose(docker, ["run", "--rm", "--no-deps", "--user", "0", "api", "/app/openmission-api", "prepare-runtime"])
            try Data().write(to: prepared, options: .atomic)
        }
        progress("Starting OpenMission and waiting for its services…")
        try await compose(docker, ["up", "-d", "--no-recreate", "--wait", "--wait-timeout", "240"], update: progress)
        guard await LocalAPI(base: ui).isOpenMission() else { throw SetupError("The UI could not reach the OpenMission API. Retry to check startup.") }
    }

    func checkAvailablePorts() throws {
        for port in ports {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw SetupError("Could not check port \(port).") }
            defer { close(fd) }
            // Accepted connections can linger briefly after Docker releases a listening port.
            var reuse: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse))) == 0 else {
                throw SetupError("Could not check port \(port).")
            }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard result == 0, listen(fd, 1) == 0 else { throw SetupError("Port \(port) is already in use. Free it and retry.") }
        }
    }
}
