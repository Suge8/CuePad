#if os(macOS)
import CueAgent
import CueStore
@testable import CuePi
import Foundation
import Testing
@testable import CuePad

/// 每个会话都属于一个任务叶子：不经任务开的会话（终端里的 Pi、只在会话文件里找到的历史），Mac 建同名任务挂上，看板与 Cue 都从任务看到它。
struct SessionTaskTests {
    let rig = TestApp()
    var services: AppServices { rig.services }
    var store: CueStore { services.store }

    @Test func 终端里开的会话_看板出现同名任务_Cue看得到_名字跟着会话_没说话就退出时一起删() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        try await store.setDirectory("/work/x", for: project.id)
        try await services.resetPiState()  // Mac 启动
        var session = CuePi.PiSession(
            id: "s1.100", sessionID: "s1", agent: .pi, sessionFile: URL(filePath: "/tmp/never-\(UUID().uuidString).jsonl"), pid: 100,
            cwd: URL(filePath: "/work/x", directoryHint: .isDirectory), terminal: PiTerminal(), extensionVersion: PiExtensionBundle.version,
            state: .settled, stateSince: .now)
        session.name = "修登录"
        try await bridge(.appeared(session))

        let row = try #require(try await TaskBoard.read(from: store).inProgress.first)
        #expect(row.task.title == "修登录" && row.project?.id == project.id && row.session?.sessionID == "s1")
        let overview = try #require(await CueTools(store: store).call("task", ["action": "peek", "all": true]))
        #expect(!overview.isError && overview.text.contains("圆桌：\n- 修登录（\(row.task.id.shortID)） · 用户自己 · 歇着"))

        session.name = "修登录跳转"
        try await bridge(.infoChanged(session))
        #expect(try await store.card(row.task.id)?.title == "修登录跳转")

        try await bridge(.ended(session, reason: .closed(reason: "quit")))
        #expect(try await store.card(row.task.id) == nil)
    }

    @Test func 启动时只在会话文件里的历史会话_挂上已完成并归档的同名任务_不占看板() async throws {
        let directory = rig.piPaths.sessionsDirectory.appending(path: "--work-x--")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "old.jsonl")
        try """
            {"type":"session","version":3,"id":"old","timestamp":"2026-09-01T08:00:00.000Z","cwd":"/work/x"}
            {"type":"message","id":"u1","parentId":null,"timestamp":"2026-09-01T08:00:01.000Z","message":{"role":"user","content":"整理发布脚本","timestamp":1}}

            """.write(to: file, atomically: true, encoding: .utf8)
        await services.consumePiHistory(AsyncStream { continuation in
            continuation.yield(.updated(try! PiHistory.index(file: file, from: nil, transcript: false, files: store.files)))
            continuation.yield(.backfillFinished(sessionFiles: [file]))
            continuation.finish()
        }, agent: .pi)

        try await services.resetPiState()  // 升级后第一次启动：已有的游离会话归位

        let task = try #require(try await store.archived().first)
        #expect(task.title == "整理发布脚本" && task.status == .done && task.piSessionID == "old")
        #expect(try await TaskBoard.read(from: store).order.isEmpty)
    }

    private func bridge(_ change: PiSessionChange) async throws {
        try await services.consumePiChanges(AsyncStream { continuation in
            continuation.yield(change)
            continuation.finish()
        })
    }
}
#endif
