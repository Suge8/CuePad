#if os(iOS)
import CueStore
import CueSync
import Foundation
import Testing
@testable import CuePad

/// 手机在前台时的会话提示：本机已同步来的会话状态出现"等你确认"、"做完了"转换时，窗口顶上弹一行（点它进该会话）；
/// 正看着那个会话时不弹。转换的判定是 `PiAlert` 的同一条规则（Mac 置位推送标志也用它），这里只管"读到的版本"怎么变成提示。
@MainActor
struct SessionNoticeTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func recorder() -> PiStateRecorder { PiStateRecorder(store: store, hostID: "mac") }

    private func live() async throws -> [PiSessionState] {
        try await store.piSessionPage(PiSessionQuery(scope: .live, limit: .max)).items.map(\.state)
    }

    @Test func 第一次读到只记基线_之后的转换才提示_同一版本不重复() async throws {
        let recorder = recorder()
        var tracker = SessionAlertTracker()
        try await recorder.update(sessionID: "s1", state: .thinking, title: "homepage")
        #expect(tracker.alerts(for: try await live()).isEmpty)

        try await recorder.update(sessionID: "s1", state: .settled)
        let settled = try await live()
        let alerts = tracker.alerts(for: settled)
        #expect(alerts.map(\.kind) == [.settled] && alerts.first?.title == "homepage")
        #expect(alerts.first?.session == settled.first?.id)
        #expect(tracker.alerts(for: settled).isEmpty)
    }

    @Test func 等你确认带问题首行_做完了不带() async throws {
        let recorder = recorder()
        var tracker = SessionAlertTracker()
        try await recorder.update(sessionID: "s1", state: .thinking, title: "homepage")
        _ = tracker.alerts(for: try await live())

        let question = PiQuestion(promptID: "p", kind: .select, text: "要覆盖 feed.xml 吗？\n会丢掉手写的条目", options: ["覆盖", "取消"])
        try await recorder.update(sessionID: "s1", state: .waitingForUser, question: question)
        let waiting = try #require(tracker.alerts(for: try await live()).first)
        #expect(waiting.kind == .waitingForUser && waiting.text.visible == "homepage 在等你 · 要覆盖 feed.xml 吗？")

        try await recorder.update(sessionID: "s1", state: .thinking)
        _ = tracker.alerts(for: try await live())
        try await recorder.update(sessionID: "s1", state: .settled)
        let settled = try #require(tracker.alerts(for: try await live()).first)
        #expect(settled.kind == .settled && settled.text.visible == "homepage · 完成了")
    }

    @Test func 会话结束后重新出现_不当成新转换() async throws {
        let recorder = recorder()
        var tracker = SessionAlertTracker()
        try await recorder.update(sessionID: "s1", state: .thinking)
        _ = tracker.alerts(for: try await live())
        try await recorder.end(sessionID: "s1")
        #expect(tracker.alerts(for: try await live()).isEmpty)  // 已结束的不在在线范围里

        try await recorder.update(sessionID: "s1", state: .settled)
        #expect(tracker.alerts(for: try await live()).isEmpty)  // 重新连上：第一次读到
    }

    // MARK: 正看着

    private func navigation(_ layout: Navigation.Layout) -> Navigation {
        let navigation = Navigation(settings: AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!, launchArguments: [:]))
        navigation.layout = layout
        return navigation
    }

    @Test func 正看着的会话_只有它在最上面一页且标签在屏幕上才算() {
        let session = UUID()
        let other = UUID()
        let tabs = navigation(.tabs)
        tabs.tab = .agent
        tabs.agentPath = [.session(session)]
        #expect(tabs.isViewing(session: session) && !tabs.isViewing(session: other))

        tabs.tab = .projects  // 切走了：Agent 标签里压着的会话页不在屏幕上
        #expect(!tabs.isViewing(session: session))

        tabs.tab = .agent
        tabs.agentPath = [.session(session), .project(UUID())]  // 上面又推了别的页
        #expect(!tabs.isViewing(session: session))

        let split = navigation(.split)
        split.splitPath = [.session(session)]
        #expect(split.isViewing(session: session))
    }

    /// 正看着 Agent 列表时也不弹会话的前台提示：列表里那一行已经在变，再弹一条横幅只会压在列表顶上。
    @Test func 正看着Agent列表或那个会话时不弹提示_别处照弹() {
        let session = UUID()
        let tabs = navigation(.tabs)
        tabs.tab = .agent
        #expect(!tabs.showsAlert(about: session))
        tabs.agentPath = [.session(UUID())]  // 列表上推了别的会话
        #expect(tabs.showsAlert(about: session))
        tabs.agentPath = [.session(session)]
        #expect(!tabs.showsAlert(about: session))
        tabs.tab = .projects
        #expect(tabs.showsAlert(about: session))

        let split = navigation(.split)
        #expect(split.showsAlert(about: session))
        split.agentPanel = true  // iPad 右侧的 Agent 面板开着
        #expect(!split.showsAlert(about: session))
        split.agentPanel = false
        split.splitRoot = .agent
        #expect(!split.showsAlert(about: session))
    }

    @Test func 点提示进该会话_同点开推送通知() {
        let session = UUID()
        let navigation = navigation(.tabs)
        navigation.show(session: session)
        #expect(navigation.tab == .agent && navigation.agentPath == [.session(session)])
    }
}
#endif
