#if os(macOS)
@testable import CuePi
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 没有自带会话名的会话（Pi、Codex 托管）有了第一句话，承载它的 Mac 请它那一家按这句话起个短名、写回成会话名；
/// 你起过名（绑着的任务有标题、发过改名）就不写，起名失败保持原名、不再试。起名的那一家是替身（`NamingLink`）：
/// 真实的 Pi 扩展与 Codex 起名见 CuePiTests 的 `RealPiTests`、`RealCodexHostedTests`。
@MainActor
struct SessionNamingTests {
    let app = TestApp()
    var store: CueStore { app.services.store }
    nonisolated static let first = "帮我看看登录页为什么白屏"
    nonisolated static let suggested = "修复登录页白屏"

    /// 替身：记下被要求起名时拿到的第一句话；`held` 时停在起名中，等测试 `release`；改名照 Pi 那样把会话名报回桥上。
    final class NamingLink: SessionLink {
        weak var bridge: PiBridge?
        var reply: Result<String, any Error> = .success(SessionNamingTests.suggested)
        var held = false
        private(set) var asked: [String] = []
        private(set) var renamed: [String] = []
        private var waiting: CheckedContinuation<Void, Never>?

        func suggestName(from firstMessage: String, in id: PiSession.ID) async throws -> String {
            asked.append(firstMessage)
            if held { await withCheckedContinuation { waiting = $0 } }
            return try reply.get()
        }

        func release() {
            waiting?.resume()
            waiting = nil
        }

        func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?, in id: PiSession.ID) async throws {
            guard let name else { return }
            renamed.append(name)
            bridge?.update(id) { $0.name = name }
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
            #expect(link.asked == [Self.first] && link.renamed == [Self.suggested])
            #expect(try await shown() == Self.suggested)
        }
    }

    @Test func 起名时绑上的任务有了标题_不写回_名字是任务标题() async throws {
        let link = NamingLink()
        link.held = true
        try await live(link) {
            try await eventually("开始起名") { !link.asked.isEmpty }
            _ = try await eventually(store, { try $0.piSessions(sessionIDs: ["p1"])["p1"] != nil }) { $0 }
            let task = try await Workspace(services: app.services).createTask("登录白屏", in: Project.defaultID)
            try await store.bindSession("p1", to: task.id)
            link.release()
            await quietPeriod(.milliseconds(300))
            #expect(link.renamed.isEmpty, "写回前再核对一遍：任务标题为准")
            #expect(try await shown() == "登录白屏")
        }
    }

    @Test func 起名时你先改了名_不盖过你起的() async throws {
        let link = NamingLink()
        link.held = true
        try await live(link) {
            try await eventually("开始起名") { !link.asked.isEmpty }
            let state = try await eventually(store, { try $0.piSessions(sessionIDs: ["p1"])["p1"]?.state }) { $0 != nil }
            try await app.services.rename(try #require(state), to: "我起的名字")
            link.release()
            await quietPeriod(.milliseconds(300))
            #expect(link.renamed.isEmpty, "发过改名就不写起好的名字")
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
            #expect(link.asked.count == 1 && link.renamed.isEmpty)
            #expect(try await shown() == Self.first)
        }
    }
}
#endif
