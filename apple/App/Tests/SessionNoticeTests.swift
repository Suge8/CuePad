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
        app.services.liveSessions.apply(try await LiveSessions.Page.read(from: store), at: .always())
        return app.services.liveSessions.live
    }

    @Test func 第一次读到只记基线_之后的转换才提示一次_等你确认带问题首行() async throws {
        let recorder = recorder()
        var tracker = SessionAlertTracker()
        try await recorder.update(sessionID: "s1", state: .thinking, title: "homepage")
        #expect(tracker.alerts(for: try await live(), cue: nil, since: .distantPast).isEmpty)

        try await recorder.update(sessionID: "s1", state: .settled)
        let settled = try await live()
        let done = tracker.alerts(for: settled, cue: nil, since: .distantPast)
        #expect(done.map(\.kind) == [.settled] && done.first?.text.visible == "homepage：完成了")
        #expect(done.first?.session == settled.first?.id)
        #expect(tracker.alerts(for: settled, cue: nil, since: .distantPast).isEmpty)

        let question = PiQuestion(promptID: "p", kind: .select, text: "要覆盖 feed.xml 吗？\n会丢掉手写的条目", options: ["覆盖", "取消"])
        try await recorder.update(sessionID: "s1", state: .waitingForUser, question: question)
        let waiting = try #require(tracker.alerts(for: try await live(), cue: nil, since: .distantPast).first)
        #expect(waiting.kind == .waitingForUser && waiting.text.visible == "homepage 在等你：要覆盖 feed.xml 吗？")
    }

    /// App 不在前台时发生的转换（冷启动、从后台回来后才同步到）不在前台补报：那一下系统推送已经提示过了。
    @Test func 回到前台之前就发生的转换不补报_之后的照常提示() async throws {
        let recorder = recorder()
        var tracker = SessionAlertTracker()
        let start = Date(timeIntervalSinceNow: -600)
        try await recorder.update(sessionID: "s1", state: .thinking, title: "notes", times: PiTimes(stateSince: start, busySince: start))
        _ = tracker.alerts(for: try await live(), cue: nil, since: .distantPast)

        let away = start.addingTimeInterval(60), active = start.addingTimeInterval(120)
        try await recorder.update(sessionID: "s1", state: .settled, times: PiTimes(stateSince: away, busySince: nil))
        #expect(tracker.alerts(for: try await live(), cue: nil, since: active).isEmpty)

        try await recorder.update(sessionID: "s1", state: .thinking, times: PiTimes(stateSince: active.addingTimeInterval(10), busySince: active.addingTimeInterval(10)))
        _ = tracker.alerts(for: try await live(), cue: nil, since: active)
        try await recorder.update(sessionID: "s1", state: .settled, times: PiTimes(stateSince: active.addingTimeInterval(20), busySince: nil))
        #expect(tracker.alerts(for: try await live(), cue: nil, since: active).map(\.kind) == [.settled])
    }

    // MARK: 正看着

    @Test func 开着那个会话时不弹提示_别处照弹() {
        let session = UUID()
        let workspace = Workspace(services: app.services)
        #expect(workspace.showsAlert(about: session))  // Cue 页
        workspace.showSessions()
        #expect(workspace.showsAlert(about: session))
        workspace.push(.session(UUID()))  // 列表上推了别的会话
        #expect(workspace.showsAlert(about: session))
        workspace.path = [.session(session)]
        #expect(!workspace.showsAlert(about: session))
        workspace.select(.cue)
        workspace.push(.session(session))  // Cue 页里点进了这个会话
        #expect(!workspace.showsAlert(about: session))
    }

    /// 提示弹出后才进了那个会话：横幅当场撤下，不在正看着的会话页上停满 5 秒。
    @Test func 进了提示说的那个会话_横幅撤下_别的提示留着() {
        let session = UUID()
        let workspace = Workspace(services: app.services)
        let banner = Workspace.Notice(text: Dotted("notes", "完成了"), tone: .done, link: .session(session))
        let other = Workspace.Notice(text: Dotted("已复制"), tone: .done)
        #expect(workspace.keeps(banner) && workspace.keeps(other))

        workspace.show(.session(session))
        #expect(!workspace.keeps(banner) && workspace.keeps(other))
    }

}
#endif
