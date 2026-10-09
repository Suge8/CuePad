import CueStore
import Foundation
import Testing
@testable import CuePad

/// 会话行（Agent 页、Mac 侧栏、Agent 整页、菜单栏面板共用）显示的状态与第三行：
/// 刚开、还没有任何一轮的会话是"新会话"，不是"该你了"或"有新回复"；做完一轮才算轮到你；
/// 回复框里有没发的草稿时，第三行写草稿。
@MainActor
struct AgentRowTests {
    let app = TestApp()
    var store: CueStore { app.services.store }
    var settings: AppSettings { app.services.settings }

    private func item() async throws -> PiSessionListItem {
        try #require(try await store.piSessionPage(PiSessionQuery()).items.first)
    }

    /// 旧扩展的会话不再在对话上浮一张说明卡：状态写在会话页顶上的玻璃标题里，点标题看这一句怎么接上；别的状态没有这句。
    @Test func 需要reload的会话_点标题看怎么接上_别的状态没有说明() {
        #expect(PiShown(status: .restart).explanation == "这个会话还在用升级前的旧版扩展，CuePad 看不到它的进展、也发不进去。在终端里对这个会话执行 /\u{2060}reload 就能接上。")
        #expect(PiShown(status: .working(.thinking)).explanation == nil)
        #expect(PiShown(status: .ended).explanation == nil)
    }

    @Test func 终端里刚开的会话是新会话_不是该你了() async throws {
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "fresh", state: .settled, title: "fresh")

        #expect(settings.shown(try await item()).label == "新会话")
    }

    @Test func 做完一轮后是有新回复_看过后是该你了() async throws {
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "atlas", state: .settled, title: "atlas")
        try await store.writePiTranscript(PiTranscript(
            sessionID: "atlas", messages: [], recap: PiRecap(lastPrompt: "跑一下测试", lastReply: "全部通过。")))

        let done = try await item()
        #expect(settings.shown(done).label == "有新回复")

        settings.markSeen(done.state, at: .now.addingTimeInterval(1))
        #expect(settings.shown(try await item()).label == "该你了")
    }

    /// 停下后的三态（新会话、有新回复、该你了）各是一种图形，都不用对勾：对勾只表示完成与记下，"轮到你了"不能读成"做完了"。
    @Test func 停下后的三态图形各不相同_都不是对勾() {
        let settled = [PiShown(status: .fresh), PiShown(status: .unread), PiShown(status: .idle)]
        #expect(Set(settled.map(\.symbol)).count == 3)
        #expect(settled.allSatisfy { !$0.symbol.contains("checkmark") })
        #expect(Set(settled.map(\.label)) == ["新会话", "有新回复", "该你了"])
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

    }

    /// 停着的会话（空闲、需要重载）没有回答时（如这一轮被中止）写你最后说的那句，比写一个状态词有用；
    /// 列表的第二层与书架、侧栏项目行的"此刻"读的是同一句（`PiProgress`）。有回答时照旧是回答。
    @Test func 停着的会话没有回答时写你最后说的那句() async throws {
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        try await recorder.update(sessionID: "s", state: .settled, title: "s")
        try await store.writePiTranscript(PiTranscript(sessionID: "s", messages: [], recap: PiRecap(lastPrompt: "把排序改成稳定的\n再跑一遍", lastReply: nil)))
        let idle = try await item()
        #expect(PiRowLine.of(idle.state, draft: nil, end: nil) == .progress("你：把排序改成稳定的"))
        #expect(PiProgress.line(of: idle.state) == "你：把排序改成稳定的")

        try await recorder.update(sessionID: "s", state: .incompatible, title: "s")
        #expect(PiProgress.line(of: try await item().state) == "你：把排序改成稳定的")

        try await store.writePiTranscript(PiTranscript(sessionID: "s", messages: [], recap: PiRecap(lastPrompt: "把排序改成稳定的", lastReply: "改好了。全部通过。")))
        #expect(PiProgress.line(of: try await item().state) == "改好了。")
    }

    /// 已结束的会话第二层一律说它做了什么，状态只由带斜线的状态标表达：最后一句回答，没有回答写你最后说的话，
    /// 都没记下就空着——不写"已结束"（翻历史时一屏都是同一个词）。
    @Test func 已结束的会话第二层写做了什么_不写已结束() async throws {
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        try await recorder.update(sessionID: "s", state: .ended, title: "s")
        func lead() async throws -> PiRowLine? {
            let ended = try await item()
            return PiRowLine.lead(ended.state, shown: settings.shown(ended), draft: nil, end: nil)
        }
        #expect(try await lead() == nil)

        try await store.writePiTranscript(PiTranscript(sessionID: "s", messages: [], recap: PiRecap(lastPrompt: "规划投送队列的重试边界\n先列方案", lastReply: nil)))
        #expect(try await lead() == .progress("你：规划投送队列的重试边界"))

        try await store.writePiTranscript(PiTranscript(sessionID: "s", messages: [], recap: PiRecap(lastPrompt: "规划投送队列的重试边界", lastReply: "列好了三个方案。第二个最稳。")))
        #expect(try await lead() == .progress("列好了三个方案。"))
    }
}
