import CueStore
import Foundation
import Testing
@testable import CuePad

/// Cue 此刻（`CueNow`）：名牌、小组件与 iPhone 的实时活动读同一份——数字账、一件一行（等你、推进中、刚做完）、第一件等你；
/// 在实时活动上"允许一次"走 Cue 页回答的同一个方法，下一件等你接上来（会话在问的只能打开）；Cue 问到的那件会话还在跑就一直在推进中；没活了实时活动就该结束；
/// 刚做完的不压住在跑的，到点自己收掉。
struct CueActivityTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }

    @Test func Cue此刻是岛与Cue那一行的同一份_允许一次后下一件接上_没活了就结束() async throws {
        let workspace = Workspace(services: rig.services)
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let release = try await store.createTask("发布 v1.4", in: project.id)
        let step = try await store.createTask("推送到 TestFlight", under: release.id)
        let canvas = try await store.createTask("画布缩放", in: project.id)
        let readme = try await store.createTask("README 截图换成 Swift 版", in: project.id)
        try await workspace.toggle(readme.id)
        let push = try await store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "推送 v1.4 到 TestFlight"), task: step.id)
        let recorder = try await rig.runtimeRecorder(on: "mac-a")
        try await recorder.update(sessionID: "testflight", state: .thinking, title: "testflight")
        try await store.bindSession("testflight", to: step.id)
        try await recorder.update(sessionID: "zoom", state: .thinking, title: "canvas-zoom")
        try await store.bindSession("zoom", to: canvas.id)
        try await recorder.update(sessionID: "zoom", state: .waitingForUser, question: PiQuestion(promptID: "p", kind: .confirm, text: "改锚点？\n会动到缩放"))

        // 实时活动只在 iPhone 上：按手机推（和 iCloud 对过、不是哪台 Mac），Mac 上的本机事实在 CueGateTests
        func now() async throws -> CueNow { CueNow(try await CueDigest.read(from: store), at: .always(), local: CueNow.Local(waiting: nil, here: nil)) }
        func kinds(_ now: CueNow) -> [CueNow.Item.Kind] { now.items.map(\.kind) }

        // 两件等你：Cue 问发布、画布的会话在问；发布的会话在跑，Cue 问它不占着它，仍在推进中；加刚做完的那件。第一件是 Cue 的提问，能"允许一次"
        var cue = try await now()
        #expect(kinds(cue) == [.asks, .asks, .running, .done] && cue.advancing == 1 && cue.isLive)
        let first = try #require(cue.first)
        #expect(first.title == "可以推送 v1.4 到 TestFlight 吗？" && first.detail == nil && first.open == DeepLink.cue.url)
        let allow = try #require(first.allow)
        #expect(allow.message == push.id && allow.choice == CueAsk.once)

        // 允许一次（实时活动在 App 进程里调的就是它）：会话在问的接上来，只能打开
        try await rig.services.answerCueQuestion(allow.message, allow.choice)
        cue = try await now()
        #expect(kinds(cue) == [.asks, .running, .done] && cue.advancing == 1)
        #expect(cue.items[1].name == "发布 v1.4")
        #expect(cue.first == CueNow.Wait(
            title: "canvas-zoom", detail: "改锚点？", open: DeepLink.session(PiSessionState.recordID(sessionID: "zoom")).url, allow: nil))

        // 答完会话的提问：两件都在跑
        try await recorder.update(sessionID: "zoom", state: .thinking)
        cue = try await now()
        #expect(kinds(cue) == [.running, .running, .done])

        // 两件都做完、会话都结束：只剩刚做完的，没活了，实时活动该结束；刚做完的那件过了一阵自己收掉
        try await workspace.toggle(canvas.id)
        try await workspace.toggle(release.id)
        try await recorder.update(sessionID: "zoom", state: .ended)
        try await recorder.update(sessionID: "testflight", state: .ended)
        cue = try await now()
        #expect(kinds(cue) == [.done, .done, .done] && !cue.isLive && cue.first == nil)
        #expect(cue.aged(to: cue.at.addingTimeInterval(CueNow.doneWindow + 1)).items.isEmpty)

        // 启用 Cue（运行在 mac-cue，那台醒着）：歇着时那一句说刚做完的那件，到点收掉后是静着
        _ = try await store.updateCueProfile { profile in
            profile.hostID = "mac-cue"
            profile.enabledAt = .now
        }
        try await store.recordMacPresence(host: "mac-cue") { true }
        cue = try await now()
        #expect(cue.ledger.isEmpty && cue.quietLine == "刚做完「发布 v1.4」" && cue.quietWord == "做完")
        #expect(cue.aged(to: cue.at.addingTimeInterval(CueNow.doneWindow + 1)).quietLine == CueNow.quiet)

        // Cue 自己开始想：手上没活也算有活，岛开着；过时之后只信慢的事实
        try await store.setCueState(.thinking)
        cue = try await now()
        #expect(cue.isLive && cue.isBusy && cue.quietWord == "在想" && cue.staleAfter == CueNow.fastStale)
        #expect(cue.settled.unconfirmed && cue.settled.isLive && !cue.settled.hasConfirmedActivity)

        // 刚做完一件又派出一件在跑，Cue 歇下：数字账写推进中那件，不停在"做完"
        let ship = try await store.createTask("推送并发新版", in: project.id)
        try await recorder.update(sessionID: "ship", state: .thinking, title: "ship")
        try await store.bindSession("ship", to: ship.id)
        try await store.setCueState(.settled)
        cue = try await now()
        #expect(cue.spoken == "1 件推进中" && cue.needsYou == 0)
    }

    @Test func Cue话未确认不沿用旧忙碌也不结束活动_迟到回执后按真实状态继续() async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing)
        let workspace = Workspace(services: app.services), store = app.services.store
        defer { app.services.cancelBackgroundWork() }
        _ = try await store.updateCueProfile { profile in
            profile.hostID = "mac-cue"
            profile.enabledAt = clock.now
        }
        try await store.recordMacPresence(host: "mac-cue") { true }
        try await store.setCueState(.thinking)
        await workspace.speak("检查部署结果", to: .cue).value
        let message = try #require(try await store.cueMessagesToDeliver().first)
        clock.advance(.seconds(Speech.sendLimit + Speech.receiptLimit + 1))
        func now() async throws -> CueNow {
            CueNow(try await CueDigest.read(from: store), at: .always(at: clock.now), local: .init(waiting: nil, here: nil))
        }
        let uncertain = try await now()
        #expect(!uncertain.isBusy && uncertain.unconfirmed && uncertain.isLive && !uncertain.hasConfirmedActivity)
        #expect(try await store.cueMessagesToDeliver().map(\.id) == [message.id])
        try await store.markCueMessagesDelivered([message.id], at: clock.now)
        try await store.setCueState(.tool, detail: "read · deploy.log")
        let confirmed = try await now()
        #expect(confirmed.isBusy && confirmed.hasConfirmedActivity && !confirmed.unconfirmed)
        try await store.setCueState(.settled)
        #expect(try await !now().isLive)
    }

}
