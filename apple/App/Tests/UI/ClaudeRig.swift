#if os(macOS)
import AppKit
import CueAgent
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePad
@testable import CueBridge

@MainActor
final class ClaudeRig {
    let work: URL
    let bin: URL
    let bridge: Bridge
    let services: AppServices
    let model: FakeModel
    var store: CueStore { services.store }
    var runtime: ClaudeCodeRuntime { services.runtimes[.claudeCode] as! ClaudeCodeRuntime }

    init(wrapper: String? = nil, hostedIdle: Duration = AgentTimeouts.hostedIdle) async throws {
        try PinnedAgent.claude.require()
        let root = TestLibraries.makeDirectory()
        let workDirectory = root.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        work = URL(filePath: ClaudeCode.realPath(workDirectory), directoryHint: .isDirectory)
        model = try await FakeModel()
        let sockets = URL(filePath: "/tmp/crig-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let environment = ClaudeSandbox.environment(model: model, root: root).merging(["CUEPAD_PI_SOCKET_DIR": sockets.path]) { $1 }
        try ClaudeSandbox.seed(config: root.appending(path: "config"), trusting: work)
        let bin = wrapper == nil ? PinnedAgent.claude.bin : root.appending(path: "wrapper", directoryHint: .isDirectory)
        if let wrapper {
            try TestScript.install("#!/bin/sh\n. \"$0.env\"\n\(wrapper)\n", at: bin.appending(path: "claude"), variables: ["REAL": PinnedAgent.claude.executable.path])
        }
        self.bin = bin
        let paths = PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: sockets, binDirectory: root.appending(path: "home/.local/bin"))
        let agentPaths = AgentPaths(pi: paths, environment: environment.merging([
            "CODEX_HOME": root.appending(path: "codex").path, "OPENCODE_CONFIG_DIR": root.appending(path: "opencode").path,
            "GROK_HOME": root.appending(path: "grok").path, "CUEPAD_AGENTS_DIR": root.appending(path: "agents").path,
            "DSH_HOME": root.appending(path: "dsh").path,
        ]) { $1 })
        let helper = root.appending(path: "CuePad.app/Contents/Helpers/cuepad")
        let agents = AgentIntegration(paths: agentPaths, locate: { [bin] in ExecutableLocator(searchDirectories: [bin]) })
        let location = try LibraryLocation.resolve(environment: [LibraryLocation.environmentKey: root.appending(path: "Library").path])
        let bridge = Bridge(socketDirectory: sockets, hostedIdle: hostedIdle)
        let mac = MacDependencies(
            bridge: bridge, hotkeys: InMemoryHotkeys(), paths: agentPaths, agents: AgentIntegrations(agents),
            hostID: TestApp.hostID, workspaces: Workspaces(root: root.appending(path: "CuePad", directoryHint: .isDirectory)),
            wakeNotifications: NotificationCenter(), timing: .system,
            commandLineTool: CommandLineToolInstaller(helper: helper, linkDirectory: root.appending(path: "home/.local/bin"), shellPath: { nil }),
            updater: nil,
            runtimes: { store in [.claudeCode: ClaudeCodeRuntime(
                bridge: bridge, paths: agentPaths, store: store, brief: SessionBrief.text(cuepad: helper), claude: { bin.appending(path: "claude") },
                locate: { ExecutableLocator(searchDirectories: [bin]) })] },
            pasteboard: NSPasteboard(name: .init("crig-\(UUID().uuidString)")),
            cue: CueDependencies(launch: { _, _ in nil }, helper: realPi, notifier: RecordingCueNotifier()))
        services = try AppServices(location: location, defaults: TempDefaults().defaults, sync: .custom(FakeSync()), mac: mac)
        services.connectAgents([.claudeCode])
        LibraryLedger.tracking(services.store, createdAt: #_sourceLocation)
        self.bridge = bridge
    }

    static func run(wrapper: String? = nil, hostedIdle: Duration = AgentTimeouts.hostedIdle, _ body: (ClaudeRig) async throws -> Void) async throws {
        let rig = try await ClaudeRig(wrapper: wrapper, hostedIdle: hostedIdle)
        do {
            rig.services.start()
            try await body(rig)
        } catch {
            await rig.shutdown()
            throw error
        }
        await rig.shutdown()
    }

    func shutdown() async {
        let followers = services.cancelBackgroundWork()
        _ = await services.beginShutdown()()
        await followers?.value
        let stray = ((try? String(contentsOf: bin.appending(path: "pids"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Int32($0) }
        for pid in stray where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    func replies(of sessionID: String) async throws -> [String] {
        guard let indexed = try await store.indexedSession(sessionID) else { return [] }
        let text = (try? String(contentsOf: URL(filePath: indexed.path), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["message"] as? [String: Any], message["role"] as? String == "assistant" else { return nil }
            if let text = message["content"] as? String { return text }
            return (message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        }
    }
}
#endif
