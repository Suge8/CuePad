import CueStore
import Foundation
import Testing
@testable import CuePad

/// 会话行（Agent 页、Mac 侧栏、Agent 整页、菜单栏面板共用）显示的状态与第三行：
/// 刚开、还没有任何一轮的会话是"新会话"，不是"待你回复"或"有新回复"；做完一轮才算等你回复；
/// 回复框里有没发的草稿时，第三行写草稿。
@MainActor
struct AgentRowTests {
    let app = TestApp()
    var store: CueStore { app.services.store }
    var settings: AppSettings { app.services.settings }

    private func item() async throws -> PiSessionListItem {
        try #require(try await store.piSessionPage(PiSessionQuery()).items.first)
    }

    @Test func 终端里刚开的会话是新会话_不是待你回复() async throws {
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "fresh", state: .settled, title: "fresh")

        #expect(settings.shown(try await item()).label == "新会话")
    }

    @Test func 做完一轮后是有新回复_看过后是待你回复() async throws {
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "atlas", state: .settled, title: "atlas")
        try await store.writePiTranscript(PiTranscript(
            sessionID: "atlas", messages: [], recap: PiRecap(lastPrompt: "跑一下测试", lastReply: "全部通过。")))

        let done = try await item()
        #expect(settings.shown(done).label == "有新回复")

        settings.markSeen(done.state, at: .now.addingTimeInterval(1))
        #expect(settings.shown(try await item()).label == "待你回复")
    }

    @Test func 回复框有草稿时第三行是草稿_清空后回到最后的回答() async throws {
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "atlas", state: .settled, title: "atlas")
        try await store.writePiTranscript(PiTranscript(
            sessionID: "atlas", messages: [], recap: PiRecap(lastPrompt: "跑一下测试", lastReply: "全部通过。共 214 个。")))
        let session = try await item().state
        settings.setReplyDraft(ComposerDraft(text: "改完再跑一遍\n顺便看看覆盖率"), for: session.id)

        #expect(PiRowLine.of(session, draft: settings.draftPreview(for: session.id), end: nil) == .draft("改完再跑一遍"))

        settings.setReplyDraft(ComposerDraft(text: "  \n"), for: session.id)
        #expect(PiRowLine.of(session, draft: settings.draftPreview(for: session.id), end: nil) == .progress("全部通过。"))
    }

    /// 整页的行只有两层：名字一层，下面一句最要紧的话。等你确认时就是问题、出错时是原因，状态由状态标表达，不再写状态词；
    /// 没有这样一句话时才写状态词。
    @Test func 整页行的第二层_有要紧的话只写那句_没有时才写状态词() async throws {
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        try await recorder.update(sessionID: "ask", state: .waitingForUser, detail: "部署到生产吗？", title: "ask")
        let ask = try await item()
        #expect(PiRowLine.lead(ask.state, shown: settings.shown(ask), draft: nil, end: nil) == .progress("部署到生产吗？"))

        try await recorder.update(sessionID: "ask", state: .ended, title: "ask")
        let ended = try await item()
        #expect(PiRowLine.lead(ended.state, shown: settings.shown(ended), draft: nil, end: nil) == .status("已结束"))
    }
}
