import CloudKit
import CueStore
@testable import CueSync
// 测试共用的支撑（临时库目录、测试图片、条件等待）与 Kit 的测试同一份；整个测试目标都能用
@_exported import CueTestSupport
import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import CuePad
#if os(macOS)
import AppKit
@testable import CueBridge
#else
import UIKit
#endif


final class TempDefaults {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "cuepad-defaults-\(UUID().uuidString)", directoryHint: .isDirectory)
    let defaults: UserDefaults

    init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = Self.open(directory)
    }

    func reopened() -> UserDefaults { Self.open(directory) }

    private static func open(_ directory: URL) -> UserDefaults { UserDefaults(suiteName: directory.appending(path: "preferences").path)! }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

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

    func stop() async {
        state.withLock { $0.stopped += 1 }
        for hung in hanging.withLock({ $0.stop() }) { hung.resume() }
    }
    /// 立即同步一直不返回，直到同步停下（同真的引擎：停了在途的才收尾）。
    let syncNowHangs = Mutex(false)
    private let hanging = Mutex(Hanging())

    private struct Hanging {
        var stopped = false
        var waiters: [CheckedContinuation<Void, Never>] = []

        mutating func stop() -> [CheckedContinuation<Void, Never>] {
            stopped = true
            defer { waiters = [] }
            return waiters
        }

        mutating func wait(_ waiter: CheckedContinuation<Void, Never>) -> Bool {
            if !stopped { waiters.append(waiter) }
            return !stopped
        }
    }

    @discardableResult func syncNow() async throws -> SyncPullResult {
        state.withLock { $0.syncNows += 1 }
        if syncNowHangs.withLock({ $0 }) {
            await withCheckedContinuation { waiter in
                if !hanging.withLock({ $0.wait(waiter) }) { waiter.resume() }
            }
        }
        return .noData
    }
    let uploads = AsyncStream<String>.makeStream()
    let sendsSucceed = Mutex(true)
    let sendingGate = Mutex<AsyncStream<Void>?>(nil)
    func send(recordNames: Set<String>) async -> Bool {
        if let gate = sendingGate.withLock({ $0 }) { for await _ in gate { break } }
        for name in recordNames.sorted() { uploads.continuation.yield(name) }
        return sendsSucceed.withLock { $0 }
    }
    func push() async {}
    func activated() async {}

    func resolve(_ resolution: SyncResolution) async throws {}
    var fileTransfers: AsyncStream<[String: FileTransfer]> { AsyncStream { $0.yield([:]) } }
    let fetching = Mutex<(@Sendable (String) async throws -> URL)?>(nil)
    func fetchFile(_ key: String) async throws -> URL {
        guard let fetch = fetching.withLock({ $0 }) else { throw FileFetchFailure.notSyncing }
        return try await fetch(key)
    }
}

/// iOS 用私有命名剪贴板：模拟器的通用剪贴板会与 Mac 同步。`relaunch()` 用同一批目录与偏好再起一个实例。
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
    lazy var bridge = Bridge(socketDirectory: socketDirectory, timing: timing)
    lazy var host = RecordingHost(bridge: bridge, socketDirectory: socketDirectory, sessions: piPaths.sessionsDirectory)
    lazy var claude = PipedHostedAgent(bridge: bridge, agent: .claudeCode)
    #else
    let pasteboardName = UIPasteboard.Name("cuepad-tests-\(UUID().uuidString)")
    #endif
    private(set) var services: AppServices!

    private let syncSource: AppServices.SyncSource?
    private let timing: Timing
    private let createdAt: SourceLocation
    private let ledger: LibraryLedger?

    #if os(macOS)
    private let cue: CueDependencies?
    private let updater: (any AppUpdater)?
    /// 这台的标识：两台设备连同一个云替身时，另一台给别的（演手机：它看的是那台 Mac 写下的，经投送请求让那台做）。
    let hostID: String
    init(
        sync source: AppServices.SyncSource? = nil, cue: CueDependencies? = nil, updater: (any AppUpdater)? = nil, timing: Timing = .system,
        host: String = TestApp.hostID, createdAt: SourceLocation = #_sourceLocation
    ) {
        hostID = host
        syncSource = source
        self.timing = timing
        self.cue = cue
        self.updater = updater
        self.createdAt = createdAt
        ledger = LibraryLedger.opening(createdAt: createdAt)
        services = makeServices()
    }
    #else
    init(sync source: AppServices.SyncSource? = nil, timing: Timing = .system, createdAt: SourceLocation = #_sourceLocation) {
        syncSource = source
        self.timing = timing
        self.createdAt = createdAt
        ledger = LibraryLedger.opening(createdAt: createdAt)
        services = makeServices()
    }
    #endif

    /// 同真的 App 退出：Mac 走退出的收尾（后台工作、执行器、Cue、桥、同步都停）。不停的话后台任务一直攥着整套服务和资料库，
    /// 换账号的通知又是全进程的，测试结束后它还会跟着并行的测试去认账号、拉取。deinit 里等不了：收尾交给 `.releasesLibraries`，用例结束时等它做完再查释放。
    isolated deinit {
        #if os(macOS)
        // 退出流程只取消跟随者、不等它们退场；它们退场前攥着服务与资料库，CI 慢时超过检查的宽限
        let followers = services.cancelBackgroundWork(), finish = services.beginShutdown()
        LibraryLedger.close(ledger, app: createdAt) {
            _ = await finish()
            await followers?.value
        }
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: socketDirectory)
        #else
        retire(services, app: createdAt)
        UIPasteboard.remove(withName: pasteboardName)
        #endif
    }

    @discardableResult
    func relaunch() -> AppServices {
        retire(services)
        services = makeServices()
        return services
    }

    /// 旧实例自己的工作都停下（同进程被杀）：桥、托管的会话和热键是 `TestApp` 的，留给新实例。不写离线之类的收尾记录，免得晚到的写入盖过新实例的。
    private func retire(_ services: AppServices, app: SourceLocation? = nil) {
        let halted = services.halt()
        LibraryLedger.close(ledger, app: app) {
            for step in halted.steps { try? await step.run() }
            await halted.followers?.value
        }
    }

    func runtimeRecorder(on host: String, boot: String = TestBoot.id) async throws -> StateRecorder {
        try await services.store.runtimeRecorder(on: host, boot: boot, minInterval: .zero, timing: timing)
    }

    /// （`services.start()` 或 `startSync()`）：替身只有一条状态流，起两遍就是两处在读。
    func syncs(reconciled: Bool = true) async throws {
        sync.emit(SyncState(status: .idle, issues: [], reconciled: reconciled))
        try await eventually("对过一遍：\(reconciled)") { services.syncing.knowsSyncedFacts == reconciled }
    }

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
    var workspaces: Workspaces { Workspaces(root: directory.appending(path: "CuePad", directoryHint: .isDirectory)) }

    /// 这台 Mac 写下自己能用 Pi（开新会话只从 macAgents 选 Agent）：探测本身起真 Agent，只在 Kit 的 Real* 测试里验，这里直接写下它的结果。
    func offersPi() async throws {
        try await services.store.recordMacAgents(host: Self.hostID, name: "测试 Mac", [MacAgent(kind: .pi, model: nil, models: [])])
    }

    /// 接入一家 Agent（会话索引只为接入了的建）：放一个只报版本的假可执行文件，再装上 CuePad 的文件，状态按磁盘上的文件检测。
    /// 假的 Pi 还像桥扩展的探测模式那样报出模型（登录了），所以这台 Mac 上能用它（同步表 macAgents）；其余几家问不出模型。
    func connect(_ kind: AgentKind, version: String = "2.1.299") async throws {
        try install(kind, version: version)
        try await services.agents.install(kind)
        await services.agents.detect(kind)
        #expect(services.agents.status(kind)?.files == .current)
    }

    func install(_ kind: AgentKind, version: String = "2.1.299", signedIn: Bool = true) throws {
        let line = signedIn ? Self.piProbeLine : #"{"cuepadProbe":{"model":null,"models":[]}}"#
        let probe = kind == .pi ? "[ -n \"$CUEPAD_PROBE\" ] && { echo '\(line)'; exit 0; }\n" : ""
        try executable(kind.facts.command, "#!/bin/sh\n\(probe)echo '\(version)'\n", in: bin)
    }

    func installClaude() throws {
        try executable(AgentKind.claudeCode.facts.command, Self.fakeClaude(loginFails: false), in: bin)
    }

    func installNode(_ version: String) throws {
        try executable("node", "#!/bin/sh\necho '\(version)'\n", in: bin)
    }

    private var bin: URL { directory.appending(path: "bin") }

    private func executable(_ name: String, _ script: String, in directory: URL) throws {
        try TestScript.install(script, at: directory.appending(path: name))
    }

    private static let piProbeLine = #"{"cuepadProbe":{"model":{"provider":"fake","id":"m","name":"M","thinking":["off"]},"models":[{"provider":"fake","id":"m","name":"M","thinking":["off"]}]}}"#

    var agentIntegration: AgentIntegration {
        let bin = bin, installers = installers.path
        return AgentIntegration(
            paths: AgentPaths(pi: piPaths, environment: agentHomes), locate: { ExecutableLocator(searchDirectories: [bin]) },
            cuepad: helper, installCommand: { kind, _ in "mkdir -p '\(bin.path)' && cp '\(installers)/\(kind.facts.command)' '\(bin.path)/'" })
    }

    private var installers: URL { directory.appending(path: "installers") }

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

    var agentHomes: [String: String] {
        ["CLAUDE_CONFIG_DIR": directory.appending(path: "claude").path, "CODEX_HOME": directory.appending(path: "codex").path,
         "OPENCODE_CONFIG_DIR": directory.appending(path: "opencode").path, "GROK_HOME": directory.appending(path: "grok").path,
         "XDG_STATE_HOME": directory.appending(path: "state").path, "CUEPAD_AGENTS_DIR": directory.appending(path: "agents").path,
         "CUEPAD_AGENTS_CONFIG_DIR": directory.appending(path: "config/agents").path, "DSH_HOME": directory.appending(path: "dsh").path,
         "HOME": directory.appending(path: "home").path]
    }

    private func makeServices() -> AppServices {
        let mac = MacDependencies(
            bridge: bridge,
            hotkeys: hotkeys,
            paths: AgentPaths(pi: piPaths, environment: agentHomes),
            agents: AgentIntegrations(agentIntegration),
            hostID: hostID,
            workspaces: workspaces,
            wakeNotifications: wakeCenter,
            timing: timing,
            commandLineTool: CommandLineToolInstaller(helper: helper, linkDirectory: piPaths.binDirectory, shellPath: { nil }),
            updater: updater,
            runtimes: { [host, claude] _ in [.pi: host, .claudeCode: claude] },
            pasteboard: pasteboard,
            cue: cue ?? CueDependencies(launch: { _, _ in nil }, helper: helper, notifier: RecordingCueNotifier()))
        let services = try! AppServices(location: isolatedLocation, defaults: preferences.defaults, sync: syncSource ?? .custom(sync), mac: mac)
        ledger?.track(services.store, createdAt: createdAt)
        return services
    }
    #else
    var pasteboard: UIPasteboard { UIPasteboard(name: pasteboardName, create: true)! }

    private func makeServices() -> AppServices {
        let services = try! AppServices(
            location: isolatedLocation, defaults: preferences.defaults, sync: syncSource ?? .custom(sync), pasteboard: pasteboard, timing: timing)
        ledger?.track(services.store, createdAt: createdAt)
        return services
    }
    #endif
}

extension Task {
    /// 取消并等它收尾：用例自己起的任务结束前还攥着它捕获的服务与资料库，`.releasesLibraries` 紧接着就查。
    func stop() async {
        cancel()
        _ = await result
    }
}

extension Workspace {
    func said(_ draft: ComposerDraft, to session: SessionState, mode: DeliveryMode, card: UUID? = nil) async throws -> DeliveryRequest {
        var box = draft
        let binding = Binding(get: { box }, set: { box = $0 })
        await speak(to: .session(session, mode: mode, card: card), from: binding) { $0.stored }.value
        return try #require(try await services.store.deliveryRequests().first)
    }
}

extension CueStore {
    func allSessionStates() throws -> [SessionState] {
        try sessionPage(SessionQuery(limit: .max)).items.map(\.state)
    }
}

extension CKRecord {
    nonisolated static func peerFloor(_ version: Int) -> CKRecord {
        let record = CKRecord(recordType: PeerFloor.recordType, recordID: PeerFloor(zoneID: CloudSync.zoneID).id)
        record[PeerFloor.field] = version as NSNumber
        return record
    }
}
