import CloudKit
import CueStore
@testable import CueSync
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

    isolated deinit {
        LibraryLedger.close(ledger, app: createdAt, services.close())
        #if os(macOS)
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: socketDirectory)
        #else
        UIPasteboard.remove(withName: pasteboardName)
        #endif
    }

    func see(_ session: SessionState, at moment: Date = .now.addingTimeInterval(1)) async throws {
        try await services.store.mark(.sessionSeen(session.sessionID), at: moment)
        services.liveSessions.apply(try await LiveSessions.Page.read(from: services.store), at: .always())
    }

    @discardableResult
    func relaunch() -> AppServices {
        LibraryLedger.close(ledger, services.close(keepingBridge: true))
        services = makeServices()
        return services
    }

    func runtimeRecorder(on host: String, boot: String = TestBoot.id) async throws -> StateRecorder {
        try await services.store.runtimeRecorder(on: host, boot: boot, minInterval: .zero, timing: timing)
    }

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
    lazy var helper = directory.appending(path: "CuePad.app/Contents/Helpers/cuepad")
    var workspaces: Workspaces { Workspaces(root: directory.appending(path: "CuePad", directoryHint: .isDirectory)) }

    func offersPi() async throws {
        try await services.store.recordMacAgents(host: Self.hostID, name: "测试 Mac", [MacAgent(kind: .pi, model: nil, models: [])])
    }

    func connect(_ kind: AgentKind, version: String = "2.1.299") async throws {
        try install(kind, version: version)
        await services.agents.detect(kind)
        #expect(services.agents.status(kind)?.isAvailable == true)
        services.connectAgents([kind])
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
            installCommand: { kind, _ in "mkdir -p '\(bin.path)' && cp '\(installers)/\(kind.facts.command)' '\(bin.path)/'" })
    }

    private var installers: URL { directory.appending(path: "installers") }

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

extension AppServices {
    /// 用例收尾的唯一一处：Mac 上走退出时的那一套（停桥、托管的 Agent、热键与同步）；`keepingBridge` 是 relaunch 换一份服务，
    /// 桥与托管的 Agent 归 TestApp、还要给新的那份用，同 iOS 只停服务自己的组件。返回等它们都走完的那一步。
    func close(keepingBridge: Bool = false) -> @Sendable () async throws -> Void {
        #if os(macOS)
        if !keepingBridge {
            let followers = cancelBackgroundWork(), finish = beginShutdown()
            return {
                _ = await finish()
                await followers?.value
            }
        }
        #endif
        let halted = halt()
        return {
            var failure: (any Error)?
            for step in halted.steps {
                do { try await step.run() } catch { failure = failure ?? error }
            }
            await halted.stopSync()
            await halted.followers?.value
            if let failure { throw failure }
        }
    }

    func upload(_ records: UUID...) async {
        _ = await sync?.send(recordNames: Set(records.map { $0.uuidString.lowercased() }))
    }
}
