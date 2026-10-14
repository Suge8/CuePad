import CueStore
import CueSync
// 测试共用的支撑（临时库目录、测试图片、条件等待）与 Kit 的测试同一份；整个测试目标都能用
@_exported import CueTestSupport
import Foundation
import Synchronization
@testable import CuePad
#if os(macOS)
import AppKit
@testable import CuePi
import Testing
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

/// 记录调用的同步引擎替身；`emit` 推一个状态快照给订阅者。
nonisolated final class FakeSync: SyncControlling, Sendable {
    private struct State {
        var started = 0
        var stopped = 0
        var syncNows = 0
        var resolutions: [String] = []
    }

    private let state = Mutex(State())
    private let updates: AsyncStream<SyncState>
    private let continuation: AsyncStream<SyncState>.Continuation
    let startError = Mutex<(any Error)?>(nil)

    init() { (updates, continuation) = AsyncStream.makeStream() }

    var started: Int { state.withLock { $0.started } }
    var stopped: Int { state.withLock { $0.stopped } }
    var syncNows: Int { state.withLock { $0.syncNows } }
    var resolutions: [String] { state.withLock { $0.resolutions } }

    var stateUpdates: AsyncStream<SyncState> { updates }

    func emit(_ state: SyncState) { continuation.yield(state) }

    func start() async throws {
        state.withLock { $0.started += 1 }
        if let error = startError.withLock({ $0 }) { throw error }
    }

    /// 为 true 时 `stop()` 永不返回（模拟卡住的同步引擎）。
    let stopHangs = Mutex(false)

    func stop() async {
        state.withLock { $0.stopped += 1 }
        if stopHangs.withLock({ $0 }) { try? await Task.sleep(for: .seconds(3600)) }
    }
    func syncNow() async throws { state.withLock { $0.syncNows += 1 } }
    func pullChanges() async throws {}
    func preparePull() async throws {}
    /// 立即上传过的记录名，按调用顺序。
    let uploads = AsyncStream<String>.makeStream()
    func sendNow(recordName: String, deleted: Bool) async throws { uploads.continuation.yield(recordName) }

    func resolve(_ resolution: SyncResolution) async throws {
        state.withLock { $0.resolutions.append("\(resolution)") }
    }
}

/// 一次"App 启动"：临时库目录 + 独立偏好 + 替身（macOS 的发送通道、热键、窗口；iOS 的私有命名剪贴板，
/// 模拟器的通用剪贴板会与 Mac 同步）。`relaunch()` 用同一批目录与偏好再起一个实例。
final class TestApp {
    let directory = TestLibraries.makeDirectory()
    let preferences = TempDefaults()
    let sync = FakeSync()
    #if os(macOS)
    static let hostID = "mac-test"
    let wakeCenter = NotificationCenter()
    let hotkeys = InMemoryHotkeys()
    /// 复制的去处（私有命名剪贴板，不碰系统的）。
    let pasteboard = NSPasteboard(name: .init("cuepad-tests-\(UUID().uuidString)"))
    /// socket 路径有 104 字节上限，所以假扩展的目录放在短路径下。
    let socketDirectory = URL(filePath: "/tmp/cat-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
    lazy var pi = PiBridge(socketDirectory: socketDirectory)
    lazy var host = RecordingHost(bridge: pi, socketDirectory: socketDirectory)
    /// 测试里的 Pi 可执行文件（执行器启动会话时用；不真运行）
    nonisolated static let piExecutable = URL(filePath: "/opt/test/bin/pi")
    let window = RecordingWindow()
    #else
    let pasteboardName = UIPasteboard.Name("cuepad-tests-\(UUID().uuidString)")
    #endif
    private(set) var services: AppServices!

    /// 同步引擎的来源；默认用记录型替身 `sync`。
    private let syncSource: AppServices.SyncSource?

    #if os(macOS)
    /// Cue 的依赖；默认本机没有能用的运行时（Cue 一直睡着）。
    private let cue: CueDependencies?

    init(sync source: AppServices.SyncSource? = nil, cue: CueDependencies? = nil) {
        syncSource = source
        self.cue = cue
        services = makeServices()
    }
    #else
    init(sync source: AppServices.SyncSource? = nil) {
        syncSource = source
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

    private var isolatedLocation: LibraryLocation {
        try! LibraryLocation.resolve(environment: [LibraryLocation.environmentKey: directory.appending(path: "Library").path])
    }

    #if os(macOS)
    var piPaths: PiPaths {
        PiPaths(agentDirectory: directory.appending(path: "pi-agent"), socketDirectory: socketDirectory, binDirectory: directory.appending(path: "home/.local/bin"))
    }
    /// App 里的命令行工具在哪（技能与命令行链接指向它）；改了之后 `relaunch()` 就是"App 移动到这里再启动"。
    lazy var helper = directory.appending(path: "CuePad.app/Contents/Helpers/cuepad")

    /// 接入一家 Agent（会话索引只为接入了的建）：放一个只报版本的假可执行文件，再装上 CuePad 的文件，状态按磁盘上的文件检测。
    /// Codex 的钩子信任平时由 `codex app-server` 写（真 Codex 的那一步只在 Kit 的 Real* 测试里验）：这里替它把信任写进 `config.toml`。
    func connect(_ kind: AgentKind) async throws {
        let bin = directory.appending(path: "bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appending(path: kind.command)
        try "#!/bin/sh\necho 2.1.0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        if kind == .codex { try installCodexTrustedLikeCodex() }
        else { try await services.agents.install(kind) }
        await services.agents.detect(kind)
        #expect(services.agents.status(kind)?.files == .current)
    }

    /// CuePad 写技能与钩子，信任写成 Codex 记下的样子（`[hooks.state."<键>"]` 下一行 `trusted_hash`）。
    private func installCodexTrustedLikeCodex() throws {
        let integration = agentIntegration
        let hooks = try #require(integration.hooks(.codex) as? CodexHooks).hooks
        let command = integration.hookCommand(.codex)
        let skill = integration.skillFile(.codex)
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AgentSkill.text(for: .codex, cuepad: helper).write(to: skill, atomically: true, encoding: .utf8)
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
        AgentIntegration(
            paths: AgentPaths(pi: piPaths, environment: agentHomes), locate: { [directory] in ExecutableLocator(searchDirectories: [directory.appending(path: "bin")]) },
            cuepad: helper)
    }

    /// 其余 Agent 的配置目录也在临时目录里，按它们自己认的环境变量给。
    var agentHomes: [String: String] {
        ["CLAUDE_CONFIG_DIR": directory.appending(path: "claude").path, "CODEX_HOME": directory.appending(path: "codex").path,
         "OPENCODE_CONFIG_DIR": directory.appending(path: "opencode").path, "XDG_STATE_HOME": directory.appending(path: "state").path]
    }

    private func makeServices() -> AppServices {
        let mac = MacDependencies(
            pi: pi,
            hotkeys: hotkeys,
            paths: AgentPaths(pi: piPaths, environment: agentHomes),
            agents: agentIntegration,
            terminal: PiTerminalJumper(),
            hostID: Self.hostID,
            wakeNotifications: wakeCenter,
            commandLineTool: CommandLineToolInstaller(helper: helper, linkDirectory: piPaths.binDirectory, shellPath: { nil }),
            updater: nil,
            hooks: AgentHookServer(path: piPaths.hookSocket),
            runtimes: { [host] _ in [.pi: host] },
            pasteboard: pasteboard,
            cue: cue ?? CueDependencies(
                scan: { [] }, launch: { _, _ in nil }, helper: helper, notifier: RecordingCueNotifier()))
        let services = try! AppServices(location: isolatedLocation, defaults: preferences.defaults, sync: syncSource ?? .custom(sync), mac: mac)
        services.windowShell = WindowShell(window: window)
        return services
    }
    #else
    var pasteboard: UIPasteboard { UIPasteboard(name: pasteboardName, create: true)! }

    private func makeServices() -> AppServices {
        try! AppServices(location: isolatedLocation, defaults: preferences.defaults, sync: syncSource ?? .custom(sync), pasteboard: pasteboard)
    }
    #endif
}

extension CueStore {
    /// 全部会话记录（测试核对用；界面按范围与页读，见 `piSessionPage`）。
    func allPiSessionStates() throws -> [PiSessionState] {
        try piSessionPage(PiSessionQuery(limit: .max)).items.map(\.state)
    }
}
