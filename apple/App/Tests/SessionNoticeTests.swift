import CueStore
import CueSync
import Foundation
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct SessionNoticeTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func recorder() -> StateRecorder { StateRecorder(store: store, hostID: "mac") }

    private func live() async throws -> [SessionListItem] {
        app.services.sessionFeed.apply(try await SessionFeed.Page.read(from: store), at: .always())
        return app.services.sessionFeed.live
    }

    @Test func 第一次读到只记基线_做完了等这一轮的回答读到才提示一次_提示里是这一轮说的话() async throws {
        let recorder = recorder()
        var tracker = SessionAlertTracker()
        try await recorder.update(sessionID: "s1", state: .thinking, title: "homepage", turnStartedAt: .now)
        #expect(tracker.alerts(for: try await live(), cue: nil, since: .distantPast).isEmpty)

        try await recorder.update(sessionID: "s1", state: .settled)
        #expect(tracker.alerts(for: try await live(), cue: nil, since: .distantPast).isEmpty)
        let recap = Recap(lastPrompt: "修首页", lastReply: "## 结论\n**修好了**，`feed.xml` 没动。\n\n```\nswift test\n```\n- 测试全过", answeredAt: .now)
        try await store.writeTranscript(SessionTranscript(sessionID: "s1", messages: [], recap: recap))
        let settled = try await live()
        let done = tracker.alerts(for: settled, cue: nil, since: .distantPast)
        #expect(done.map(\.kind) == [.settled] && done.first?.reply?.hasPrefix("修好了") == true)
        #expect(done.first?.session == settled.first?.id)
        #expect(tracker.alerts(for: settled, cue: nil, since: .distantPast).isEmpty)

        let question = Question(promptID: "p", kind: .select, text: "要覆盖 feed.xml 吗？\n会丢掉手写的条目", options: ["覆盖", "取消"])
        try await recorder.update(sessionID: "s1", state: .waitingForUser, question: question)
        let waiting = try #require(tracker.alerts(for: try await live(), cue: nil, since: .distantPast).first)
        #expect(waiting.kind == .waitingForUser && waiting.question?.hasPrefix("要覆盖 feed.xml 吗") == true)
    }

    @Test func 歇下后回答还没读到就又动起来_不提示() async throws {
        let recorder = recorder()
        var tracker = SessionAlertTracker()
        try await recorder.update(sessionID: "s1", state: .thinking, title: "homepage", turnStartedAt: .now)
        _ = tracker.alerts(for: try await live(), cue: nil, since: .distantPast)
        try await recorder.update(sessionID: "s1", state: .settled)
        _ = tracker.alerts(for: try await live(), cue: nil, since: .distantPast)

        try await recorder.update(sessionID: "s1", state: .thinking, turnStartedAt: .now)
        try await store.writeTranscript(SessionTranscript(sessionID: "s1", messages: [], recap: Recap(lastPrompt: "修首页", lastReply: "修好了", answeredAt: .now)))
        #expect(tracker.alerts(for: try await live(), cue: nil, since: .distantPast).isEmpty)
    }

    @Test func 回到前台之前就发生的转换不补报_之后的照常提示() async throws {
        let recorder = recorder()
        var tracker = SessionAlertTracker()
        let start = Date(timeIntervalSinceNow: -600)
        try await recorder.update(sessionID: "s1", state: .thinking, title: "notes", times: SessionTimes(stateSince: start, busySince: start))
        _ = tracker.alerts(for: try await live(), cue: nil, since: .distantPast)

        let away = start.addingTimeInterval(60), active = start.addingTimeInterval(120)
        try await recorder.update(sessionID: "s1", state: .settled, times: SessionTimes(stateSince: away, busySince: nil))
        #expect(tracker.alerts(for: try await live(), cue: nil, since: active).isEmpty)

        let again = active.addingTimeInterval(10)
        try await recorder.update(sessionID: "s1", state: .thinking, times: SessionTimes(stateSince: again, busySince: again), turnStartedAt: again)
        _ = tracker.alerts(for: try await live(), cue: nil, since: active)
        try await store.writeTranscript(SessionTranscript(sessionID: "s1", messages: [], recap: Recap(lastPrompt: "记一下", lastReply: "记好了", answeredAt: again.addingTimeInterval(5))))
        try await recorder.update(sessionID: "s1", state: .settled, times: SessionTimes(stateSince: active.addingTimeInterval(20), busySince: nil))
        #expect(tracker.alerts(for: try await live(), cue: nil, since: active).map(\.kind) == [.settled])
    }

    #if os(iOS)
    // MARK: 正看着

    @Test func 开着那个会话时不弹提示_别处照弹() {
        let session = UUID()
        let workspace = Workspace(services: app.services)
        #expect(workspace.showsAlert(about: session))
        workspace.push(.search)
        #expect(workspace.showsAlert(about: session))
        workspace.push(.session(UUID()))
        #expect(workspace.showsAlert(about: session))
        workspace.path = [.session(session)]
        #expect(!workspace.showsAlert(about: session))
        workspace.select(.cue)
        workspace.push(.session(session))
        #expect(!workspace.showsAlert(about: session))
    }

    @Test func 进了提示说的那个会话_横幅撤下_别的提示留着() {
        let session = UUID()
        let workspace = Workspace(services: app.services)
        let banner = Workspace.Notice(text: Dotted("notes 新回复", "记好了"), tone: .done, link: .session(session))
        let other = Workspace.Notice(text: Dotted("已复制"), tone: .done)
        #expect(workspace.keeps(banner) && workspace.keeps(other))

        workspace.show(.session(session))
        #expect(!workspace.keeps(banner) && workspace.keeps(other))
    }
    #endif
}
