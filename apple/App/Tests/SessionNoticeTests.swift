#if os(iOS)
import CueStore
import CueSync
import Foundation
import Testing
@testable import CuePad

/// 手机在前台时的会话提示：本机已同步来的会话状态出现"等你确认"、"做完了"转换时，窗口顶上弹一行（点它进该会话）；
/// 正看着那个会话时不弹。转换的判定是 `PiAlert` 的同一条规则（Mac 置位推送标志也用它），这里只管"读到的版本"怎么变成提示。
struct SessionNoticeTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func recorder() -> PiStateRecorder { PiStateRecorder(store: store, hostID: "mac") }

    /// 前台提示读的版本：`LiveSessions` 里在线的（`startSessionAlerts` 同一条路）。
    private func live() async throws -> [PiSessionListItem] {
        app.services.liveSessions.apply(try await LiveSessions.Page.read(from: store))
        return app.services.liveSessions.live
    }

    @Test func 第一次读到只记基线_之后的转换才提示_同一版本不重复() async throws {
        let recorder = recorder()
        var tracker = SessionAlertTracker()
        try await recorder.update(sessionID: "s1", state: .thinking, title: "homepage")
        #expect(tracker.alerts(for: try await live(), since: .distantPast).isEmpty)

        try await recorder.update(sessionID: "s1", state: .settled)
        let settled = try await live()
        let alerts = tracker.alerts(for: settled, since: .distantPast)
        #expect(alerts.map(\.kind) == [.settled] && alerts.first?.title == "homepage")
        #expect(alerts.first?.session == settled.first?.id)
        #expect(tracker.alerts(for: settled, since: .distantPast).isEmpty)
    }

    @Test func 等你确认带问题首行_做完了不带() async throws {
        let recorder = recorder()
        var tracker = SessionAlertTracker()
        try await recorder.update(sessionID: "s1", state: .thinking, title: "homepage")
        _ = tracker.alerts(for: try await live(), since: .distantPast)

        let question = PiQuestion(promptID: "p", kind: .select, text: "要覆盖 feed.xml 吗？\n会丢掉手写的条目", options: ["覆盖", "取消"])
        try await recorder.update(sessionID: "s1", state: .waitingForUser, question: question)
        let waiting = try #require(tracker.alerts(for: try await live(), since: .distantPast).first)
        #expect(waiting.kind == .waitingForUser && waiting.text.visible == "homepage 在等你 · 要覆盖 feed.xml 吗？")

        try await recorder.update(sessionID: "s1", state: .thinking)
        _ = tracker.alerts(for: try await live(), since: .distantPast)
        try await recorder.update(sessionID: "s1", state: .settled)
        let settled = try #require(tracker.alerts(for: try await live(), since: .distantPast).first)
        #expect(settled.kind == .settled && settled.text.visible == "homepage · 完成了")
    }

    /// App 不在前台时发生的转换（冷启动、从后台回来后才同步到）不在前台补报：那一下系统推送已经提示过了。
    @Test func 回到前台之前就发生的转换不补报_之后的照常提示() async throws {
        let recorder = recorder()
        var tracker = SessionAlertTracker()
        let start = Date(timeIntervalSinceNow: -600)
        try await recorder.update(sessionID: "s1", state: .thinking, title: "notes", times: PiTimes(stateSince: start, busySince: start))
        _ = tracker.alerts(for: try await live(), since: .distantPast)

        let away = start.addingTimeInterval(60), active = start.addingTimeInterval(120)
        try await recorder.update(sessionID: "s1", state: .settled, times: PiTimes(stateSince: away, busySince: nil))
        #expect(tracker.alerts(for: try await live(), since: active).isEmpty)

        try await recorder.update(sessionID: "s1", state: .thinking, times: PiTimes(stateSince: active.addingTimeInterval(10), busySince: active.addingTimeInterval(10)))
        _ = tracker.alerts(for: try await live(), since: active)
        try await recorder.update(sessionID: "s1", state: .settled, times: PiTimes(stateSince: active.addingTimeInterval(20), busySince: nil))
        #expect(tracker.alerts(for: try await live(), since: active).map(\.kind) == [.settled])
    }

    // MARK: 正看着

    private func navigation(_ layout: Navigation.Layout) -> Navigation {
        let navigation = Navigation(settings: AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!, launchArguments: [:]))
        navigation.layout = layout
        return navigation
    }

    /// 正看着 Agent 列表时也不弹会话的前台提示：列表里那一行已经在变，再弹一条横幅只会压在列表顶上。
    /// Agent 标签的根是 Cue 页，全部会话是推进去的第二层；iPad 右侧面板是 Cue 页，不是会话列表。
    @Test func 正看着Agent列表或那个会话时不弹提示_别处照弹() {
        let session = UUID()
        let tabs = navigation(.tabs)
        tabs.tab = .agent
        #expect(tabs.showsAlert(about: session))  // Cue 页
        tabs.agentPath = [.agent]
        #expect(!tabs.showsAlert(about: session))
        tabs.agentPath = [.agent, .session(UUID())]  // 列表上推了别的会话
        #expect(tabs.showsAlert(about: session))
        tabs.agentPath = [.agent, .session(session)]
        #expect(!tabs.showsAlert(about: session))
        tabs.tab = .projects
        #expect(tabs.showsAlert(about: session))

        let split = navigation(.split)
        #expect(split.showsAlert(about: session))
        split.agentPanel = true  // iPad 右侧的面板开着：那是 Cue 页
        #expect(split.showsAlert(about: session))
        split.agentPanel = false
        split.splitRoot = .agent
        #expect(!split.showsAlert(about: session))
    }

    /// 提示弹出后才进了那个会话（或 Agent 列表）：横幅当场撤下，不在正看着的会话页上停满 5 秒。
    @Test func 进了提示说的那个会话_横幅撤下_别的提示留着() {
        let session = UUID()
        let navigation = navigation(.tabs)
        let banner = Workspace.Notice(text: "notes · 完成了", isError: false, link: .session(session))
        let other = Workspace.Notice(text: "已复制", isError: false)
        #expect(navigation.keeps(banner) && navigation.keeps(other))

        navigation.show(.session(session))
        #expect(!navigation.keeps(banner) && navigation.keeps(other))
    }

}
#endif
