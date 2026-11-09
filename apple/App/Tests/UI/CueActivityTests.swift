import CueStore
import Foundation
import Testing
@testable import CuePad

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
        try await workspace.complete(readme.id)
        let push = try await store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "推送 v1.4 到 TestFlight"), task: step.id)
        let recorder = try await rig.runtimeRecorder(on: "mac-a")
        try await recorder.update(sessionID: "testflight", state: .thinking, title: "testflight", projectID: project.id)
        try await store.bindSession("testflight", to: step.id)
        try await recorder.update(sessionID: "zoom", state: .thinking, title: "canvas-zoom", projectID: project.id)
        try await store.bindSession("zoom", to: canvas.id)
        try await recorder.update(sessionID: "zoom", state: .waitingForUser, question: PiQuestion(promptID: "p", kind: .confirm, text: "改锚点？\n会动到缩放"))

        // 实时活动只在 iPhone 上：按手机推（和 iCloud 对过、不是哪台 Mac），Mac 上的本机事实在 CueGateTests
        func now() async throws -> CueNow { CueNow(try await CueDigest.read(from: store), at: .always(), local: CueNow.Local(waiting: nil, here: nil)) }
        func kinds(_ now: CueNow) -> [CueNow.Item.Kind] { now.items.map(\.kind) }

        var cue = try await now()
        #expect(kinds(cue) == [.asks, .asks, .running, .done] && cue.advancing == 1 && cue.isLive)
        let first = try #require(cue.first)
        #expect(first.title == "可以推送 v1.4 到 TestFlight 吗？" && first.detail == nil && first.open == DeepLink.cue.url)
        let allow = try #require(first.allow)
        #expect(allow.message == push.id && allow.choice == CueAsk.once)

        try await rig.services.answerCueQuestion(allow.message, allow.choice)
        cue = try await now()
        #expect(kinds(cue) == [.asks, .running, .done] && cue.advancing == 1)
        #expect(cue.items[1].name == "发布 v1.4")
        #expect(cue.first == CueNow.Wait(
            title: "canvas-zoom", detail: "改锚点？", open: DeepLink.session(PiSessionState.recordID(sessionID: "zoom")).url, allow: nil))

        try await recorder.update(sessionID: "zoom", state: .thinking)
        cue = try await now()
        #expect(kinds(cue) == [.running, .running, .done])

        try await workspace.complete(canvas.id)
        try await workspace.complete(release.id)
        try await recorder.update(sessionID: "zoom", state: .ended)
        try await recorder.update(sessionID: "testflight", state: .ended)
        cue = try await now()
        #expect(kinds(cue) == [.done, .done, .done] && !cue.isLive && cue.first == nil)
        #expect(cue.aged(to: cue.at.addingTimeInterval(CueNow.doneWindow + 1)).items.isEmpty)

        _ = try await store.updateCueProfile { profile in
            profile.hostID = "mac-cue"
            profile.enabledAt = .now
        }
        let cueRecorder = try await rig.runtimeRecorder(on: "mac-cue")
        cue = try await now()
        #expect(cue.ledger.isEmpty && cue.quietLine == "刚做完「发布 v1.4」" && cue.quietWord == "做完")
        #expect(cue.aged(to: cue.at.addingTimeInterval(CueNow.doneWindow + 1)).quietLine == CueNow.quiet)

        try await cueRecorder.updateCue(.thinking)
        cue = try await now()
        #expect(cue.isLive && cue.isBusy && cue.quietWord == "在想" && cue.staleAfter == CueNow.fastStale)
        #expect(cue.settled.unconfirmed && cue.settled.isLive && !cue.settled.hasConfirmedActivity)

        let ship = try await store.createTask("推送并发新版", in: project.id)
        try await recorder.update(sessionID: "ship", state: .thinking, title: "ship", projectID: project.id)
        try await store.bindSession("ship", to: ship.id)
        try await cueRecorder.updateCue(.settled)
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
        let cueRecorder = try await app.runtimeRecorder(on: "mac-cue")
        try await cueRecorder.updateCue(.thinking)
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
        try await cueRecorder.updateCue(.tool, detail: "read · deploy.log")
        let confirmed = try await now()
        #expect(confirmed.isBusy && confirmed.hasConfirmedActivity && !confirmed.unconfirmed)
        try await cueRecorder.updateCue(.settled)
        #expect(try await !now().isLive)
    }

}
