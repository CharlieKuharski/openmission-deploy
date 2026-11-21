import SwiftUI
import AppKit

enum Prerequisite: String, CaseIterable, Identifiable {
    case docker = "Docker Desktop", ollama = "Ollama"
    var id: Self { self }
    var app: URL? {
        let id = self == .docker ? "com.docker.docker" : "com.electron.ollama"
        if let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return found }
        let path = self == .docker ? "/Applications/Docker.app" : "/Applications/Ollama.app"
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
    var installer: URL {
        URL(string: self == .docker ? "https://desktop.docker.com/mac/main/arm64/Docker.dmg" : "https://ollama.com/download/Ollama.dmg")!
    }
}

@MainActor
final class Launcher: ObservableObject {
    enum Page { case checking, prerequisites, models, resume, working, open, problem }
    @Published var page: Page = .checking
    @Published var message = "Checking this Mac…"
    @Published var ready = Set<Prerequisite>()
    @Published var pair: ModelPair
    @Published var installed = Set<String>()
    @Published var customizing = false
    @Published var retryingSetup = false
    @Published var downloading: Prerequisite?
    let memory: Int
    let deployment: Deployment
    private var docker: LocalDocker?
    private var destination: URL?
    private var checking = false
    private var didLaunch = false
    private let ollama = LocalAPI(base: URL(string: "http://127.0.0.1:11434")!)

    init() {
        memory = Int(ProcessInfo.processInfo.physicalMemory / (1 << 30))
        pair = .recommended(memoryGiB: memory)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        deployment = Deployment(root: support.appendingPathComponent("OpenMission"), resources: Bundle.main.resourceURL!)
    }

    func launch() async {
        guard !didLaunch else { return }
        didLaunch = true
        await check()
    }

    func check() async {
        guard !checking, page != .working, downloading == nil else { return }
        checking = true
        defer { checking = false }
        do {
            var available = Set<Prerequisite>()
            var diagnostic = ""
            docker = LocalDocker.locate()
            if let docker {
                do { try await docker.requireLocalEngine(); available.insert(.docker) }
                catch { diagnostic = error.localizedDescription }
            }
            if let docker, available.contains(.docker) {
                let stacks = try await docker.installations(managedName: deployment.name)
                let owned = stacks.filter { $0.name == deployment.name && $0.directory == deployment.root.path }
                for ui in stacks.filter({ $0.service == "ui" }) {
                    if let url = await docker.verifiedUI(ui) {
                        if ui.name == deployment.name && ui.directory == deployment.root.path {
                            let settings: ModelSettings = try await LocalAPI(base: url).request("api/settings/models")
                            if !settings.setupCompleted || FileManager.default.fileExists(atPath: deployment.pending.path) { continue }
                        }
                        open(url)
                        return
                    }
                }
                if let foreign = stacks.first(where: { $0.name != deployment.name || $0.directory != deployment.root.path }) {
                    throw SetupError("Existing installation “\(foreign.name)” is stopped or still starting. Start or inspect it in Docker Desktop, then check again.")
                }
                retryingSetup = !owned.isEmpty || FileManager.default.fileExists(atPath: deployment.pending.path)
                if owned.isEmpty { try deployment.checkAvailablePorts() }
            }
            if let catalog: Catalog = try? await ollama.request("api/tags", timeout: 3) {
                installed = Set(catalog.models.map(\.name))
                available.insert(.ollama)
            }
            ready = available
            if ready.count < 2 {
                message = diagnostic.isEmpty ? "Install or open each required app. OpenMission will check again automatically." : diagnostic
                page = .prerequisites
                return
            }
            if let previous = try deployment.choice() {
                pair = previous
            } else if FileManager.default.fileExists(atPath: deployment.root.appendingPathComponent(".runtime-prepared").path) {
                page = .resume
                return
            }
            customizing = pair.codingModel.isEmpty
            message = ""
            page = .models
        } catch { fail(error) }
    }

    func open(_ url: URL) {
        destination = url
        if NSWorkspace.shared.open(url) { page = .open; message = "OpenMission is running." }
        else { fail(SetupError("Could not open your browser. Visit \(url.absoluteString).")) }
    }
    func reopen() { if let destination { open(destination) } }

    func installOrOpen(_ prerequisite: Prerequisite) async {
        if let app = prerequisite.app {
            do {
                _ = try await NSWorkspace.shared.openApplication(at: app, configuration: .init())
                await check()
            } catch { fail(error) }
            return
        }
        downloading = prerequisite
        message = "Downloading the official \(prerequisite.rawValue) installer…"
        do {
            let (temp, response) = try await URLSession.shared.download(from: prerequisite.installer)
            guard (response as? HTTPURLResponse)?.statusCode == 200, response.url?.scheme == "https"
            else { throw SetupError("Could not download the \(prerequisite.rawValue) installer.") }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dmg = dir.appendingPathComponent(prerequisite.rawValue + ".dmg")
            try FileManager.default.moveItem(at: temp, to: dmg)
            // Preserve the normal Gatekeeper checks for Internet downloads.
            let flag = "0083;" + String(Int(Date().timeIntervalSince1970), radix: 16) + ";OpenMission;"
            guard flag.withCString({ setxattr(dmg.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }) == 0,
                  NSWorkspace.shared.open(dmg) else { throw SetupError("Could not open the downloaded installer.") }
            message = "Finish the \(prerequisite.rawValue) installer, then open the installed app."
        } catch { fail(error) }
        downloading = nil
    }

    func start() async {
        let resuming = page == .resume
        guard (resuming || page == .models), let docker else { return }
        do {
            let selection = resuming ? nil : try pair.normalized()
            let missing = selection?.missing(from: installed) ?? []
            let bytes = missing.compactMap { ModelPair.sizes[$0] }.reduce(0,+) * 1_000_000_000
            // Ollama can store models on a separate volume; its own pull reports disk errors there.
            if bytes > 0, let home = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
               let free = home.volumeAvailableCapacityForImportantUsage, Double(free) < bytes {
                throw SetupError("The recommended downloads exceed the available space on your home volume. Free space or select smaller models.")
            }
            page = .working
            message = "Preparing your installation…"
            try FileManager.default.createDirectory(at: deployment.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let lock = Darwin.open(deployment.root.appendingPathComponent(".setup.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lock >= 0 else { throw SetupError("Could not open the setup lock.") }
            defer { close(lock) }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw SetupError("Setup is already running in another OpenMission launcher.") }
            let containers = try await docker.installations(managedName: deployment.name)
            guard !containers.contains(where: { $0.name != deployment.name || $0.directory != deployment.root.path })
            else { throw SetupError("Another installation appeared. Check again to open it.") }
            if !containers.contains(where: { $0.name == deployment.name }) { try deployment.checkAvailablePorts() }
            if let selection { try deployment.initialize(selection) }
            try await deployment.start(docker) { line in Task { @MainActor in self.message = line } }
            if let selection {
                message = "Checking selected models…"
                try await LocalAPI(base: deployment.ui).configure(selection) { self.message = $0 }
            }
            try deployment.finish()
            open(deployment.ui)
        } catch { fail(error) }
    }

    private func fail(_ error: Error) { message = error.localizedDescription; page = .problem }
}

struct LauncherView: View {
    @ObservedObject var state: Launcher
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 48, height: 48)
                Text("OpenMission").font(.largeTitle.weight(.semibold))
            }
            Divider()
            switch state.page {
            case .checking, .working:
                ProgressView().controlSize(.small)
                Text(state.message).textSelection(.enabled)
            case .prerequisites:
                Text("Set up this Mac").font(.title2)
                ForEach(Prerequisite.allCases) { item in
                    HStack {
                        Text(item.rawValue); Spacer()
                        if state.ready.contains(item) { Label("Ready", systemImage: "checkmark.circle") }
                        else {
                            Button((item.app == nil ? "Install " : "Open ") + item.rawValue) {
                                Task { await state.installOrOpen(item) }
                            }.disabled(state.downloading != nil)
                        }
                    }
                }
                Text(state.message).foregroundStyle(.secondary).textSelection(.enabled)
            case .models:
                Text("Models for your \(state.memory) GB Mac").font(.title2)
                if state.memory < 16 { Text("Memory is limited for builds. Choose a coding model explicitly to continue.") }
                if state.customizing {
                    LabeledContent("Thinking") { TextField("Ollama model tag", text: $state.pair.thinkingModel) }
                    LabeledContent("Coding") { TextField("Ollama model tag", text: $state.pair.codingModel) }
                } else if state.pair.thinkingModel == state.pair.codingModel {
                    LabeledContent("Thinking and Coding", value: state.pair.thinkingModel)
                } else {
                    LabeledContent("Thinking", value: state.pair.thinkingModel)
                    LabeledContent("Coding", value: state.pair.codingModel)
                }
                if let pair = try? state.pair.normalized() {
                    ForEach(pair.unique, id: \.self) { tag in
                        let size = ModelPair.sizes[tag].map { "About \($0.formatted()) GB to download" } ?? "Download size unknown"
                        Text("\(tag) · \(state.installed.contains(tag) ? "Installed" : size)").font(.callout).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button(state.retryingSetup ? "Resume setup" : "Download and use") { Task { await state.start() } }
                        .buttonStyle(.borderedProminent).disabled((try? state.pair.normalized()) == nil)
                    if !state.customizing { Button("Choose different models") { state.customizing = true } }
                }
            case .resume:
                Text("Your OpenMission installation is stopped.").font(.title2)
                Text("Start its services and open your projects.")
                Button("Start OpenMission") { Task { await state.start() } }.buttonStyle(.borderedProminent)
            case .open:
                Text(state.message)
                Button("Open in browser") { state.reopen() }
            case .problem:
                Text("Setup needs attention").font(.title2)
                ScrollView { Text(state.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("Check again") { Task { await state.check() } }
            }
        }.padding(28).frame(width: 520).frame(minHeight: 260)
        .task { await state.launch() }
        .task(id: state.page == .prerequisites) {
            while state.page == .prerequisites && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                await state.check()
            }
        }
    }
}

@main
struct OpenMissionApp: App {
    @StateObject private var launcher = Launcher()
    var body: some Scene {
        Window("OpenMission", id: "launcher") { LauncherView(state: launcher) }
            .windowResizability(.contentSize)
    }
}
