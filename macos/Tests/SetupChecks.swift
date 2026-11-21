import Foundation

@main
enum SetupChecks {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data(("Installer check failed: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    static func run() async throws {
        for (size, t, c) in [(8,"hermes3:3b",""), (15,"hermes3:3b",""),
            (16,"qwen3.5:4b","qwen3.5:4b"), (23,"qwen3.5:4b","qwen3.5:4b"),
            (24,"qwen3.5:9b","qwen3.5:9b"), (31,"qwen3.5:9b","qwen3.5:9b"),
            (32,"hermes3:8b","qwen3-coder:30b"), (95,"hermes3:8b","qwen3-coder:30b"),
            (96,"hermes3:8b","qwen3-coder-next:q4_K_M"), (127,"hermes3:8b","qwen3-coder-next:q4_K_M"),
            (128,"hermes3:8b","qwen3-coder-next:q8_0"), (192,"hermes3:8b","qwen3-coder-next:q8_0")] {
            let pair = ModelPair.recommended(memoryGiB: size)
            precondition(pair.thinkingModel == t && pair.codingModel == c)
            precondition((try? pair.normalized()) != nil || size < 16)
        }
        let pair = try ModelPair(thinkingModel: " custom ", codingModel: "custom:latest").normalized()
        precondition(pair.unique == ["custom:latest"])
        precondition(pair.missing(from: ["custom:latest"]).isEmpty)
        let two = ModelPair.recommended(memoryGiB: 48)
        precondition(two.missing(from: [two.codingModel]) == [two.thinkingModel])
        try await verifyModelPulls()
        print("Memory tiers, custom tags, shared downloads, installed models and pull recovery passed.")
        // Optional integration harness. The caller owns the disposable root, ports and Compose project.
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty { return }
        guard let docker = LocalDocker.locate() else { throw SetupError("Docker CLI is missing") }
        try await docker.requireLocalEngine()
        if args == ["--discover"] {
            for stack in try await docker.stacks() where stack.service == "ui" {
                if let url = await docker.verifiedUI(stack) { print("Verified existing OM: \(url)"); return }
            }
            throw SetupError("No running OM UI found")
        }
        guard (4...5).contains(args.count), args[0] == "--smoke" else { throw SetupError("Expected --smoke ROOT RESOURCES THINKING_MODEL [CODING_MODEL]") }
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw SetupError("Smoke root must be new") }
        let test = Deployment(root: root, resources: URL(fileURLWithPath: args[2]), name: "om-dmg-smoke-" + UUID().uuidString.lowercased(),
                              ports: [25173,28080,28642,29119])
        let choice = try ModelPair(thinkingModel: args[3], codingModel: args.last!).normalized()
        try test.checkAvailablePorts()
        try test.initialize(choice)
        let before = try Data(contentsOf: root.appendingPathComponent(".env"))
        try test.initialize(choice)
        let after = try Data(contentsOf: root.appendingPathComponent(".env"))
        precondition(before == after)
        try Data(test.name.utf8).write(to: root.appendingPathComponent("smoke-project"))
        do {
            try await test.start(docker) { print($0) }
            let api = LocalAPI(base: test.ui)
            try await api.configure(choice) { print($0) }
            try test.finish()
            let persisted: ModelSettings = try await api.request("api/settings/models")
            precondition(persisted.setupCompleted && persisted.defaults == choice)
            if args.count == 5 {
                try await verifyStoryAndBuild(api: LocalAPI(base: URL(string: "http://127.0.0.1:\(test.ports[1])")!), choice: choice)
            }
            try await test.compose(docker, ["stop"])
            try await test.start(docker) { _ in }
            let restarted: ModelSettings = try await api.request("api/settings/models")
            guard restarted.setupCompleted, restarted.defaults == choice else { throw SetupError("Model settings lost on restart") }
            print("Isolated stack, restart and persisted role selection passed.")
        } catch {
            try await cleanUp(test, docker)
            throw error
        }
        try await cleanUp(test, docker)
    }

    static func cleanUp(_ test: Deployment, _ docker: LocalDocker) async throws {
        try await test.compose(docker, ["down", "--volumes"])
        let root = test.root.appendingPathComponent("workspace")
        let apps = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for dir in apps where dir.lastPathComponent.hasPrefix("installer-smoke-") {
            let project = "openmission-dev-" + dir.lastPathComponent
            let containers = try await docker.run(["ps", "-aq", "--filter", "label=com.docker.compose.project=" + project])
            guard !containers.isEmpty else { continue }
            let mounts = try await docker.run(["inspect", "--format", "{{range .Mounts}}{{println .Source}}{{end}}"] + containers.components(separatedBy: .newlines))
            guard mounts.components(separatedBy: .newlines).contains(dir.path) else {
                throw SetupError("Unexpected volume mount for " + project)
            }
            _ = try await docker.run(["compose", "-p", project, "-f", "compose.yaml", "down", "--volumes", "--rmi", "local"], at: dir)
        }
    }

    // Stop the disposable build as soon as Hermes verifies its coding session.
    static func verifyStoryAndBuild(api: LocalAPI, choice: ModelPair) async throws {
        struct Created: Decodable { let createdProjectId: String }
        struct Empty: Decodable {}
        struct Project: Decodable {
            struct Story: Decodable { let id: String; let story, error: String? }
            struct Event: Decodable { let phase, result: String? }
            struct Run: Decodable { let status: String; let events: [Event]?; let error: String? }
            let story: Story
            let preferredModel: String
            let goalRun: Run
        }
        let created: Created = try await api.request("api/projects", method: "POST", body: [
            "name": "Installer smoke", "prompt": "Build a single static page showing the heading Hello OpenMission. The only acceptance criterion is that the heading is visible."
        ], timeout: 360)
        let projectPath = "api/projects/" + created.createdProjectId
        let project: Project = try await api.request(projectPath)
        guard project.story.story?.isEmpty == false, project.preferredModel == choice.codingModel else {
            throw SetupError(project.story.error ?? "Missing story or incorrect coding model")
        }
        print("Generated a sample story. Starting its build to verify the coding session.")
        let _: Empty = try await api.request(projectPath + "/story/approve-and-run", method: "POST", body: ["storyId": project.story.id])
        do {
            let deadline = Date().addingTimeInterval(240)
            var confirmed = false
            while Date() < deadline {
                let state: Project = try await api.request(projectPath)
                for event in state.goalRun.events ?? [] where event.phase == "session_model_verification" {
                    guard let data = event.result?.data(using: .utf8),
                          let payload = try? JSONDecoder().decode([String:String].self, from: data) else { continue }
                    confirmed = payload["status"] == "verified" && payload["observed_model"] == choice.codingModel
                    if confirmed { break }
                }
                if confirmed { break }
                if ["failed", "canceled"].contains(state.goalRun.status) { throw SetupError(state.goalRun.error ?? "Build stopped before model verification") }
                try await Task.sleep(for: .seconds(2))
            }
            guard confirmed else { throw SetupError("Timed out waiting for the build to verify its coding model") }
        } catch {
            let _: Empty? = try? await api.request(projectPath + "/goal-run/cancel", method: "POST")
            throw error
        }
        let _: Empty = try await api.request(projectPath + "/goal-run/cancel", method: "POST")
        print("Hermes verified the selected coding model during the sample build.")
    }
}
