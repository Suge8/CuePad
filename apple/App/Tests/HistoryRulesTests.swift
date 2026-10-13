#if os(macOS)
import AppKit
import CuePi
import CueStore
import Foundation
import Testing
@testable import CuePad

/// "什么算历史"的两条规则，端到端用真实 Pi：一句话没说过的会话关掉后不进历史；CuePad 后台托管的会话闲置退出不算结束，
/// 仍在"现在"，Mac 本机与手机两条路发话都会唤醒它，只有用户结束它才进历史。
/// 真实 Pi 与真实后台托管（闲置 2 秒退出），全部状态落在临时目录，假模型零网络；不碰真实资料库与 ~/.pi。
nonisolated private let realPi = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/pi")
nonisolated private let fixtures = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "CuePadKit/Tests/CuePiTests/Fixtures")

@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: realPi.path), "需要 ~/.local/bin/pi"), .timeLimit(.minutes(4)))
struct HistoryRulesTests {
    final class Rig {
        let cwd: URL
        let host: PiHost
        let bridge: PiBridge
        let services: AppServices
        var store: CueStore { services.store }

        init() async throws {
            let directory = TestLibraries.makeDirectory()
            cwd = directory.appending(path: "work", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
            let paths = PiPaths(
                agentDirectory: directory.appending(path: "agent"),
                socketDirectory: URL(filePath: "/tmp/hr-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory),
                binDirectory: directory.appending(path: "home/.local/bin"))
            let installer = PiIntegration(
                paths: paths, locator: PiExecutableLocator(searchDirectories: [realPi.deletingLastPathComponent()]),
                helper: directory.appending(path: "CuePad.app/Contents/Helpers/cuepad"), shellPath: { nil })
            try await installer.install()
            let extensions = paths.agentDirectory.appending(path: "extensions")
            try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fixtures.appending(path: "fake-model.ts"), to: extensions.appending(path: "fake-model.ts"))

            bridge = PiBridge(socketDirectory: paths.socketDirectory)
            host = PiHost(
                bridge: bridge, paths: paths, idleLimit: .seconds(2),
                extraArguments: ["--offline", "--no-context-files", "--no-skills", "--no-prompt-templates", "--no-themes", "--model", "fake/echo", "--thinking", "off"])
            let mac = MacDependencies(
                pi: bridge, hotkeys: InMemoryHotkeys(), paths: paths, installer: installer, terminal: PiTerminalJumper(),
                hostID: TestApp.hostID, wakeNotifications: NotificationCenter(),
                updater: nil, host: host, locatePi: { realPi }, pasteboard: NSPasteboard(name: .init("hr-\(UUID().uuidString)")),
                cue: CueDependencies(scan: { [] }, launch: { _ in nil }, helper: realPi, notifier: RecordingCueNotifier()))
            let location = try LibraryLocation.resolve(environment: [LibraryLocation.environmentKey: directory.appending(path: "Library").path])
            services = try AppServices(location: location, defaults: TempDefaults().defaults, sync: .custom(FakeSync()), mac: mac)
            services.start()
            try await until("执行器在运行") { services.executor.isRunning }
        }

        func shutdown() {
            services.cancelBackgroundWork()
            // 托管的 Pi 不随 CuePad 结束：桥上还在的（本用例临时 socket 目录里的，是本用例启动的）逐个让它退出
            for session in bridge.sessions where session.hosted { kill(session.pid, SIGTERM) }
            bridge.stop()
        }

        func records(_ scope: PiSessionScope) async throws -> [PiSessionState] {
            try await store.piSessionPage(PiSessionQuery(scope: scope, limit: .max)).items.map(\.state)
        }

        /// 这个会话在会话文件里的全部回答。
        func replies(of sessionID: String) async throws -> [String] {
            guard let indexed = try await store.piSession(sessionID) else { return [] }
            let text = (try? String(contentsOf: URL(filePath: indexed.path), encoding: .utf8)) ?? ""
            return text.split(separator: "\n").compactMap { line in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let message = object["message"] as? [String: Any], message["role"] as? String == "assistant",
                      let blocks = message["content"] as? [[String: Any]] else { return nil }
                return blocks.compactMap { $0["text"] as? String }.joined()
            }
        }
    }

    /// 没有事件可订阅的跨进程等待（进程退出、文件落盘、索引跟上）：有界条件等待。
    private static func until(_ what: String, timeout: Duration = .seconds(40), _ check: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("等不到：\(what)")
    }

    // MARK: 一句话没说过的会话

    @Test func 一句话没说过的会话关掉后不进历史() async throws {
        let rig = try await Rig()
        defer { rig.shutdown() }
        let id = try await rig.host.open(in: rig.cwd, launchToken: "silent", executable: realPi).id
        try await Self.until("会话记录写出") { try await rig.records(.all).count == 1 }

        try await rig.host.end(id)

        try await Self.until("没说过话的会话记录被删（同步删除）") { try await rig.records(.all).isEmpty }
    }

    // MARK: 后台托管的会话闲置退出

    @Test func 托管会话闲置退出后仍在现在_发话唤醒回复_用户结束才进历史() async throws {
        let rig = try await Rig()
        defer { rig.shutdown() }
        let id = try await rig.host.open(in: rig.cwd, launchToken: "hosted", executable: realPi).id
        let session = try #require(rig.bridge.session(id: id))
        let sessionID = session.sessionID
        _ = try await rig.bridge.send(PiMessage(text: "开场"), to: id)
        try await Self.until("回答落盘、索引跟上") { try await rig.replies(of: sessionID).last == "ECHO 开场 IMAGES[]" }

        // 闲置退出：进程不在了，会话仍在"现在"，歇着，不进历史
        try await Self.until("闲置退出") { rig.bridge.session(sessionID: sessionID) == nil }
        try await expectResting(rig, sessionID)

        // Mac 本机发话（"已结束"那条路：执行器用会话索引在后台唤醒）
        try await rig.services.send("本机来的话", toEnded: sessionID, named: "x", card: nil)
        try await Self.until("本机发话得到回复") { try await rig.replies(of: sessionID).last == "ECHO 本机来的话 IMAGES[]" }
        try await Self.until("再次闲置退出") { rig.bridge.session(sessionID: sessionID) == nil }
        let resting = try await expectResting(rig, sessionID)

        // 手机发话（投送请求写给这台 Mac）
        let request = try await rig.services.requestMacDelivery("手机来的话", to: resting, mode: .send)
        let result = try await rig.services.outcome(of: request.id)
        #expect(result.failure == nil)
        try await Self.until("手机发话得到回复") { try await rig.replies(of: sessionID).last == "ECHO 手机来的话 IMAGES[]" }
        try await Self.until("又一次闲置退出") { rig.bridge.session(sessionID: sessionID) == nil }
        let again = try await expectResting(rig, sessionID)

        // 用户在 CuePad 里结束它：这时才进历史
        let end = try await rig.services.end(again)
        #expect(try await rig.services.outcome(of: end.id).failure == nil)
        try await Self.until("结束后进历史") { try await rig.records(.ended).map(\.sessionID) == [sessionID] }
        #expect(try await rig.records(.live).isEmpty)
    }

    /// 进程不在了、记录仍在"现在"（未结束）、不在历史里、是托管的、歇着。
    @discardableResult
    private func expectResting(_ rig: Rig, _ sessionID: String) async throws -> PiSessionState {
        let current = try await rig.store.piSessionPage(.current).items.map(\.state)
        let state = try #require(current.first { $0.sessionID == sessionID }, "仍在现在")
        #expect(state.hosted && state.state == .known(.settled), "托管、歇着")
        #expect(try await rig.records(.ended).isEmpty, "不进历史")
        return state
    }
}

/// Mac 本机：托管着、进程歇着的会话（记录在"现在"、桥上没有）是任务绑着的会话时，交出草稿在后台唤醒它。
struct RestingTargetTests {
    let rig = TestApp()

    @Test func 托管着进程歇着的会话_交出时唤醒() async throws {
        let services: AppServices = rig.services
        let workspace = Workspace(services: services)
        let store = services.store
        let project = try await store.createProject(name: "Work", color: "blue")
        let folder = rig.directory.appending(path: "work/alpha", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = "/sessions/--work-alpha--/a.jsonl"
        try await store.upsertPiSession(PiSession(id: "a", path: file, cwd: folder.path, title: "alpha", lastActivityAt: .now), host: TestApp.hostID)
        try await services.piStateRecorder.update(
            sessionID: "a", state: .settled, title: "alpha", projectID: project.id, hosted: true)
        services.startLiveSessions()
        try await services.executor.start()
        defer { services.cancelBackgroundWork() }
        let task = try await store.createTask("任务", in: project.id)
        let draft = try await store.createCard(body: "接着做", under: task.id)
        try await store.linkCard(task.id, toSession: "a")

        workspace.handOff(draft)

        try await eventually("唤醒后话送到") { rig.host.extensions["a"]?.messages.isEmpty == false }
        #expect(rig.host.calls == [.resume(sessionFile: file, directory: folder.path)])
        let request = try #require(try await store.deliveryRequests().first)
        #expect(rig.host.extensions["a"]?.messages == [PiMessage(text: "接着做", deliveryID: request.id.uuidString)])
    }
}
#endif
