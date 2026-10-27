import CueStore
import CueSync
// 测试共用的支撑（临时库目录、测试图片、条件等待）与 Kit 的测试同一份；整个测试目标都能用
@_exported import CueTestSupport
import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import CuePad
#if os(macOS)
import AppKit
@testable import CuePi
#else
import UIKit
#endif


/// 临时目录里的独立偏好存储，释放时连目录一起删除。
final class TempDefaults {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "cuepad-defaults-\(UUID().uuidString)", directoryHint: .isDirectory)
    let defaults: UserDefaults

    init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: directory.appending(path: "preferences").path)!
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

/// 记录调用的同步替身；`emit` 推一个状态快照给订阅者。
nonisolated final class FakeSync: SyncControlling, Sendable {
    private struct State {
        var started = 0
        var stopped = 0
        var syncNows = 0
    }

    private let state = Mutex(State())
    private let updates: AsyncStream<SyncState>
    private let continuation: AsyncStream<SyncState>.Continuation

    init() { (updates, continuation) = AsyncStream.makeStream() }

    var started: Int { state.withLock { $0.started } }
    var stopped: Int { state.withLock { $0.stopped } }
    var syncNows: Int { state.withLock { $0.syncNows } }

    var stateUpdates: AsyncStream<SyncState> { updates }

    func emit(_ state: SyncState) { continuation.yield(state) }

    func start() async {
        state.withLock { $0.started += 1 }
    }

    /// 为 true 时 `stop()` 永不返回（模拟卡住的同步）。
    let stopHangs = Mutex(false)

    func stop() async {
        state.withLock { $0.stopped += 1 }
        if stopHangs.withLock({ $0 }) { try? await Task.sleep(for: .seconds(3600)) }
    }
    /// 为 true 时 `syncNow()` 永不返回（像网络一直没有回音）。
    let syncNowHangs = Mutex(false)

    func syncNow() async throws {
        state.withLock { $0.syncNows += 1 }
        if syncNowHangs.withLock({ $0 }) { try? await Task.sleep(for: .seconds(3600)) }
    }
    let uploads = AsyncStream<String>.makeStream()
    func send(recordNames: Set<String>) async -> Bool {
        for name in recordNames.sorted() { uploads.continuation.yield(name) }
        return true
    }
    func push() async {}

    func resolve(_ resolution: SyncResolution) async throws {}
}

/// 一次"App 启动"：临时库目录 + 独立偏好 + 替身（macOS 的发送通道、热键；iOS 的私有命名剪贴板，
/// 模拟器的通用剪贴板会与 Mac 同步）。`relaunch()` 用同一批目录与偏好再起一个实例。
final class TestApp {
    let directory = TestLibraries.makeDirectory()
    let preferences = TempDefaults()
    let sync = FakeSync()
    #if os(macOS)
    static let hostID = "mac-test"
    let wakeCenter = NotificationCenter()
    let hotkeys = InMemoryHotkeys()
    let pasteboard = NSPasteboard(name: .init("cuepad-tests-\(UUID().uuidString)"))
    /// socket 路径有 104 字节上限，所以假扩展的目录放在短路径下。
    let socketDirectory = URL(filePath: "/tmp/cat-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    lazy var pi = PiBridge(socketDirectory: socketDirectory)
    lazy var host = RecordingHost(bridge: pi, socketDirectory: socketDirectory, sessions: piPaths.sessionsDirectory)
    /// 托管的 Claude Code 会话（撑不过 App 重启的那一类）
    lazy var claude = PipedHostedAgent(bridge: pi, agent: .claudeCode)
    #else
    let pasteboardName = UIPasteboard.Name("cuepad-tests-\(UUID().uuidString)")
    #endif
    private(set) var services: AppServices!

    /// 同步的来源；默认用记录型替身 `sync`。
    private let syncSource: AppServices.SyncSource?
    /// App 的钟（资料库、在线记录续期、说的话到点翻状态、主动拉取）；要推进时间的测试给 `ManualTiming` 的。
    private let timing: Timing

    #if os(macOS)
    /// Cue 的依赖；默认本机没有能用的运行时（Cue 一直睡着）。
    private let cue: CueDependencies?
    /// 自动更新器；默认没有（同隔离模式）。
    private let updater: (any AppUpdater)?
    /// 这台的标识：两台设备连同一个云替身时，另一台给别的（演手机：它看的是那台 Mac 写下的，经投送请求让那台做）。
    let hostID: String
    init(
        sync source: AppServices.SyncSource? = nil, cue: CueDependencies? = nil, updater: (any AppUpdater)? = nil, timing: Timing = .system,
        host: String = TestApp.hostID
    ) {
        hostID = host
        syncSource = source
        self.timing = timing
        self.cue = cue
        self.updater = updater
        services = makeServices()
    }
    #else
    init(sync source: AppServices.SyncSource? = nil, timing: Timing = .system) {
        syncSource = source
        self.timing = timing
        services = makeServices()
    }
    #endif

    isolated deinit {
        #if os(macOS)
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: socketDirectory)
        #else
        UIPasteboard.remove(withName: pasteboardName)
        #endif
    }

    @discardableResult
    func relaunch() -> AppServices {
        services.cancelBackgroundWork()
        services = makeServices()
        return services
    }

    /// 同步报来这台的库和 iCloud 对没对过一遍（`SyncState.reconciled`，启用 Cue 的前提），等服务读到。同步要已经起着
    /// （`services.start()` 或 `startSync()`）：替身只有一条状态流，起两遍就是两处在读。
    func syncs(reconciled: Bool = true) async throws {
        sync.emit(SyncState(status: .idle, issues: [], reconciled: reconciled))
        try await eventually("对过一遍：\(reconciled)") { services.knowsSyncedFacts == reconciled }
    }

    /// 隔离库的文件（直接改库里的时刻，演"很久以前"）。
    var databaseURL: URL { isolatedLocation.databaseURL }

    private var isolatedLocation: LibraryLocation {
        try! LibraryLocation.resolve(environment: [LibraryLocation.environmentKey: directory.appending(path: "Library").path])
    }

    #if os(macOS)
    var piPaths: PiPaths {
        PiPaths(agentDirectory: directory.appending(path: "pi-agent"), socketDirectory: socketDirectory, binDirectory: directory.appending(path: "home/.local/bin"))
    }
    /// App 里的命令行工具在哪（技能与命令行链接指向它）；改了之后 `relaunch()` 就是"App 移动到这里再启动"。
    lazy var helper = directory.appending(path: "CuePad.app/Contents/Helpers/cuepad")
    /// 项目工作区的根目录（没绑文件夹的项目开工时建在这里）：在临时目录里。
    var workspaces: Workspaces { Workspaces(root: directory.appending(path: "CuePad", directoryHint: .isDirectory)) }

    /// 这台 Mac 写下自己能用 Pi（开新会话只从 macAgents 选 Agent）：探测本身起真 Agent，只在 Kit 的 Real* 测试里验，这里直接写下它的结果。
    func offersPi() async throws {
        try await services.store.recordMacAgents(host: Self.hostID, name: "测试 Mac", [MacAgent(kind: .pi, model: nil, models: [])])
    }

    /// 接入一家 Agent（会话索引只为接入了的建）：放一个只报版本的假可执行文件，再装上 CuePad 的文件，状态按磁盘上的文件检测。
    /// 假的 Pi 还像桥扩展的探测模式那样报出模型（登录了），所以这台 Mac 上能用它（同步表 macAgents）；其余几家问不出模型。
    /// Codex 的钩子信任平时由 `codex app-server` 写（真 Codex 的那一步只在 Kit 的 Real* 测试里验）：这里替它把信任写进 `config.toml`。
    func connect(_ kind: AgentKind, version: String = "2.1.299") async throws {
        try install(kind, version: version)
        if kind == .codex { try installCodexTrustedLikeCodex() }
        else { try await services.agents.install(kind) }
        await services.agents.detect(kind)
        #expect(services.agents.status(kind)?.files == .current)
    }

    /// 这台 Mac 上装了这家 Agent（还没接入）：放一个只报版本的假可执行文件，Pi 的还能报出模型（`signedIn` 为 false 时没有模型，是没登录）。
    func install(_ kind: AgentKind, version: String = "2.1.299", signedIn: Bool = true) throws {
        let line = signedIn ? Self.piProbeLine : #"{"cuepadProbe":{"model":null,"models":[]}}"#
        let probe = kind == .pi ? "[ -n \"$CUEPAD_PROBE\" ] && { echo '\(line)'; exit 0; }\n" : ""
        try executable(kind.facts.command, "#!/bin/sh\n\(probe)echo '\(version)'\n", in: bin)
    }

    /// 装了 Claude Code、还没登录（同 `offersClaudeInstaller` 备的那个，探测问得出没登录）。
    func installClaude() throws {
        try executable(AgentKind.claudeCode.facts.command, Self.fakeClaude(loginFails: false), in: bin)
    }

    /// 这台 Mac 上的 Node.js（找 Agent 的同一组目录里）：只报版本。
    func installNode(_ version: String) throws {
        try executable("node", "#!/bin/sh\necho '\(version)'\n", in: bin)
    }

    private var bin: URL { directory.appending(path: "bin") }

    private func executable(_ name: String, _ script: String, in directory: URL) throws {
        try TestScript.install(script, at: directory.appending(path: name))
    }

    private static let piProbeLine = #"{"cuepadProbe":{"model":{"provider":"fake","id":"m","name":"M","thinking":["off"]},"models":[{"provider":"fake","id":"m","name":"M","thinking":["off"]}]}}"#

    /// CuePad 写技能与钩子，信任写成 Codex 记下的样子（`[hooks.state."<键>"]` 下一行 `trusted_hash`）。
    private func installCodexTrustedLikeCodex() throws {
        let integration = agentIntegration
        let hooks = try #require(integration.channel(.codex) as? CodexHooks).hooks
        let command = integration.hookCommand(.codex)
        let skill = integration.skillFile
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AgentSkill.text(cuepad: helper, for: [.codex]).write(to: skill, atomically: true, encoding: .utf8)
        try hooks.install(command: command)
        let path = hooks.file.realPath.path
        let trust = try hooks.ourGroups(in: JSONSourceTree(Data(contentsOf: hooks.file))).map { group in
            let event = try #require(CodexHooks.events.first { $0.name == group.event })
            let hash = try #require(CodexHooks.hash(event, command: command, hooks: hooks))
            return "[hooks.state.\"\(CodexHooks.key(path, group.event, group.index))\"]\ntrusted_hash = \"\(hash)\"\n"
        }
        try trust.joined(separator: "\n").write(to: hooks.file.deletingLastPathComponent().appending(path: "config.toml"), atomically: true, encoding: .utf8)
    }

    var agentIntegration: AgentIntegration {
        let bin = bin, installers = installers.path
        return AgentIntegration(
            paths: AgentPaths(pi: piPaths, environment: agentHomes), locate: { ExecutableLocator(searchDirectories: [bin]) },
            cuepad: helper, installCommand: { kind, _ in "mkdir -p '\(bin.path)' && cp '\(installers)/\(kind.facts.command)' '\(bin.path)/'" })
    }

    /// "官方安装脚本"的替身（`AgentIntegration.installCommand`）拷的东西：备好了的那家装得上，没备好的 cp 报错、装不上。
    private var installers: URL { directory.appending(path: "installers") }

    /// 备好一个装得上的 Claude Code：报版本；`auth login` 记下已登录（`loginFails` 时退出码 1、没登录上）；
    /// 探测时（stream-json 的 initialize）按登录了没有回答账号，同真的 Claude Code。
    func offersClaudeInstaller(loginFails: Bool = false) throws {
        try executable(AgentKind.claudeCode.facts.command, Self.fakeClaude(loginFails: loginFails), in: installers)
    }

    private static func fakeClaude(loginFails: Bool) -> String {
        """
        #!/usr/bin/python3
        import json, os, sys
        marker = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".logged-in")
        args = sys.argv[1:]
        if "--version" in args:
            print("2.1.299 (Claude Code)"); sys.exit(0)
        if args[:2] == ["auth", "login"]:
            if \(loginFails ? "True" : "False"): sys.exit(1)
            open(marker, "w").close(); sys.exit(0)
        signed = os.path.exists(marker)
        for line in sys.stdin:
            message = json.loads(line)
            if message.get("type") != "control_request": continue
            request = message["request"]
            if request.get("subtype") == "initialize":
                body = {"account": {"tokenSource": "claude.ai" if signed else "none", "apiProvider": "firstParty"}}
            else:
                body = {"applied": {}}
            reply = {"type": "control_response", "response": {"subtype": "success", "request_id": message["request_id"], "response": body}}
            print(json.dumps(reply), flush=True)

        """
    }

    /// 其余 Agent 的配置目录也在临时目录里，按它们自己认的环境变量给。
    var agentHomes: [String: String] {
        ["CLAUDE_CONFIG_DIR": directory.appending(path: "claude").path, "CODEX_HOME": directory.appending(path: "codex").path,
         "OPENCODE_CONFIG_DIR": directory.appending(path: "opencode").path, "GROK_HOME": directory.appending(path: "grok").path,
         "XDG_STATE_HOME": directory.appending(path: "state").path, "CUEPAD_AGENTS_DIR": directory.appending(path: "agents").path,
         "DSH_HOME": directory.appending(path: "dsh").path]
    }

    private func makeServices() -> AppServices {
        let mac = MacDependencies(
            pi: pi,
            hotkeys: hotkeys,
            paths: AgentPaths(pi: piPaths, environment: agentHomes),
            agents: AgentIntegrations(agentIntegration),
            terminal: PiTerminalJumper(),
            hostID: hostID,
            workspaces: workspaces,
            wakeNotifications: wakeCenter,
            timing: timing,
            commandLineTool: CommandLineToolInstaller(helper: helper, linkDirectory: piPaths.binDirectory, shellPath: { nil }),
            updater: updater,
            hooks: AgentHookServer(path: piPaths.hookSocket),
            runtimes: { [host, claude] _ in [.pi: host, .claudeCode: claude] },
            pasteboard: pasteboard,
            cue: cue ?? CueDependencies(launch: { _, _ in nil }, helper: helper, notifier: RecordingCueNotifier()))
        return try! AppServices(location: isolatedLocation, defaults: preferences.defaults, sync: syncSource ?? .custom(sync), mac: mac)
    }
    #else
    var pasteboard: UIPasteboard { UIPasteboard(name: pasteboardName, create: true)! }

    private func makeServices() -> AppServices {
        try! AppServices(location: isolatedLocation, defaults: preferences.defaults, sync: syncSource ?? .custom(sync), pasteboard: pasteboard, timing: timing)
    }
    #endif
}

extension Workspace {
    /// 像回复框那样从一份草稿发给会话（`speak`，关联带上的第一张卡），等写库与上传走完，返回写下的那条请求。
    func said(_ draft: ComposerDraft, to session: PiSessionState, mode: DeliveryMode, card: UUID? = nil) async throws -> DeliveryRequest {
        var box = draft
        let files = services.store.files
        let binding = Binding(get: { box }, set: { box = $0 })
        await speak(to: .session(session, mode: mode, card: card), from: binding) { try $0.stored(in: files) }?.value
        return try #require(try await services.store.deliveryRequests().first)
    }
}

extension CueStore {
    /// 全部会话记录（测试核对用；界面按范围与页读，见 `piSessionPage`）。
    func allPiSessionStates() throws -> [PiSessionState] {
        try piSessionPage(PiSessionQuery(limit: .max)).items.map(\.state)
    }
}
