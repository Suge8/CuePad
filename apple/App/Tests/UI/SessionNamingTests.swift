#if os(macOS)
@testable import CuePi
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 没有自带会话名的会话（Pi、Codex 托管）有了第一句话，承载它的 Mac 请它那一家按这句话起个短名、写回成会话名；
/// 你起过名（绑着的任务有标题、发过改名）以你的为准，这家此刻起不了（还没换上新扩展）的等能起了再起，起名失败保持原名、不再试。
/// 起名的那一家是替身（`NamingLink`）：真实的 Pi 扩展与 Codex 起名、写回见 CuePiTests 的 `RealPiTests`、`RealCodexHostedTests`。
@MainActor
struct SessionNamingTests {
    let app = TestApp()
    var store: CueStore { app.services.store }
    nonisolated static let first = "帮我看看登录页为什么白屏"
    nonisolated static let suggested = "修复登录页白屏"

    /// 替身：记下被要求起名时拿到的第一句话；`held` 时停在起名中，等测试 `release`；起好了像各家那样只在会话还没名字时写下，名字报回桥上。
    final class NamingLink: SessionLink {
        weak var bridge: PiBridge?
        var able = true
        var reply: Result<String, any Error> = .success(SessionNamingTests.suggested)
        var held = false
        private(set) var asked: [String] = []
        private var waiting: CheckedContinuation<Void, Never>?

        func canNameItself(_ id: PiSession.ID) -> Bool { able }

        func nameItself(from firstMessage: String, in id: PiSession.ID) async throws {
            asked.append(firstMessage)
            if held { await withCheckedContinuation { waiting = $0 } }
            let name = try reply.get()
            guard bridge?.session(id: id)?.name == nil else { return }
            bridge?.update(id) { $0.name = name }
        }

        func release() {
            waiting?.resume()
            waiting = nil
        }
    }

    /// 接上桥、开始记录会话变化，挂上一个只说了第一句话、还没名字的终端 Pi 会话。
    private func live(_ link: NamingLink, until stop: () async throws -> Void) async throws {
        let events = app.pi.changes()
        let consume = Task { try await app.services.consumePiChanges(events) }
        link.bridge = app.pi
        var session = PiSession(
            id: "p1.1", sessionID: "p1", agent: .pi, sessionFile: nil, pid: 1, cwd: app.directory, terminal: PiTerminal(),
            state: .settled, stateSince: .now)
        session.firstMessage = Self.first
        app.pi.attach(session, via: link)
        try await stop()
        consume.cancel()
        _ = await consume.result
        app.services.cancelBackgroundWork()
    }

    private func shown() async throws -> String? {
        try await store.piSessions(sessionIDs: ["p1"])["p1"]?.name(at: app.services.speech)
    }

    @Test func 会话有了第一句话_起好的短名成了会话名() async throws {
        let link = NamingLink()
        try await live(link) {
            _ = try await eventually(store, { try $0.piSessions(sessionIDs: ["p1"])["p1"]?.state.title }) { $0 == Self.suggested }
            #expect(link.asked == [Self.first])
            #expect(try await shown() == Self.suggested)
        }
    }

    @Test func 起名时绑上的任务有了标题_名字是任务标题() async throws {
        let link = NamingLink()
        link.held = true
        try await live(link) {
            try await eventually("开始起名") { !link.asked.isEmpty }
            _ = try await eventually(store, { try $0.piSessions(sessionIDs: ["p1"])["p1"] != nil }) { $0 }
            let task = try await Workspace(services: app.services).createTask("登录白屏", in: Project.defaultID)
            try await store.bindSession("p1", to: task.id)
            link.release()
            _ = try await eventually(store, { try $0.piSessions(sessionIDs: ["p1"])["p1"]?.state.title }) { $0 == Self.suggested }
            #expect(try await shown() == "登录白屏", "任务标题是名字的唯一事实源")
        }
    }

    @Test func 起名时你先改了名_显示你起的() async throws {
        let link = NamingLink()
        link.held = true
        try await live(link) {
            try await eventually("开始起名") { !link.asked.isEmpty }
            let state = try await eventually(store, { try $0.piSessions(sessionIDs: ["p1"])["p1"]?.state }) { $0 != nil }
            try await app.services.rename(try #require(state), to: "我起的名字")
            link.release()
            _ = try await eventually(store, { try $0.piSessions(sessionIDs: ["p1"])["p1"]?.state.title }) { $0 == Self.suggested }
            #expect(try await shown() == "我起的名字", "改名请求在起好的名字之后送到，盖过它")
        }
    }

    @Test func 绑着有标题的任务_不起名() async throws {
        let link = NamingLink()
        link.able = false
        try await live(link) {
            let task = try await Workspace(services: app.services).createTask("登录白屏", in: Project.defaultID)
            _ = try await eventually(store, { try $0.piSessions(sessionIDs: ["p1"])["p1"] != nil }) { $0 }
            try await store.bindSession("p1", to: task.id)
            link.able = true
            app.pi.update("p1.1") { $0.detail = "又说了一句" }
            _ = try await eventually(store, { try $0.piSessions(sessionIDs: ["p1"])["p1"]?.state.detail }) { $0 == "又说了一句" }
            await quietPeriod(.milliseconds(300))
            #expect(link.asked.isEmpty)
            #expect(try await shown() == "登录白屏")
        }
    }

    /// 还没换上新扩展的 Pi 会话起不了：不算试过，换上之后（会话再有变化）照常起。
    @Test func 这家此刻起不了_能起了再起() async throws {
        let link = NamingLink()
        link.able = false
        try await live(link) {
            _ = try await eventually(store, { try $0.piSessions(sessionIDs: ["p1"])["p1"] != nil }) { $0 }
            #expect(link.asked.isEmpty)
            link.able = true
            app.pi.update("p1.1") { $0.detail = "换上了新扩展" }
            _ = try await eventually(store, { try $0.piSessions(sessionIDs: ["p1"])["p1"]?.state.title }) { $0 == Self.suggested }
            #expect(link.asked == [Self.first])
        }
    }

    @Test func 起名失败_保持第一句话_不再试() async throws {
        let link = NamingLink()
        link.reply = .failure(PiBridgeError.rejected("failed: timeout"))
        try await live(link) {
            try await eventually("起过一次") { link.asked.count == 1 }
            app.pi.update("p1.1") { $0.detail = "又说了一句" }
            _ = try await eventually(store, { try $0.piSessions(sessionIDs: ["p1"])["p1"]?.state.detail }) { $0 == "又说了一句" }
            await quietPeriod(.milliseconds(300))
            #expect(link.asked.count == 1)
            #expect(try await shown() == Self.first)
        }
    }
}
#endif
