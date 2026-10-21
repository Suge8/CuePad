import CueStore
import Foundation
import Testing
@testable import CuePad

/// iPhone 的实时活动（锁屏与灵动岛）与 Cue 那一行读同一批：在管与等你的数、一排格子（每件在管、每件等你、今天做完）、第一件等你；
/// 在实时活动上"允许一次"走 Cue 页回答的同一个方法，那件回到在管、下一件等你接上来（会话在问的只能打开）；都没了实时活动就该结束。
struct CueActivityTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }

    @Test func 实时活动与Cue那一行同一批_允许一次后那件回到在管_都没了就结束() async throws {
        let workspace = Workspace(services: rig.services)
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let release = try await store.createTask("发布 v1.4", in: project.id)
        let step = try await store.createTask("推送到 TestFlight", under: release.id)
        let canvas = try await store.createTask("画布缩放", in: project.id)
        let readme = try await store.createTask("README 截图换成 Swift 版", in: project.id)
        try await workspace.toggle(readme.id)
        let push = try await store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "推送 v1.4 到 TestFlight"), task: step.id)
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        try await recorder.update(sessionID: "testflight", state: .thinking, title: "testflight")
        try await store.bindSession("testflight", to: step.id)
        try await recorder.update(sessionID: "zoom", state: .thinking, title: "canvas-zoom")
        try await store.bindSession("zoom", to: canvas.id)
        try await recorder.update(sessionID: "zoom", state: .waitingForUser, question: PiQuestion(promptID: "p", kind: .confirm, text: "改锚点？\n会动到缩放"))

        func both() async throws -> (tally: CueTally, activity: CueActivityState) {
            let reading = try await CueActivityState.Reading.read(from: store)
            return (try await CueDigest.read(from: store).tally, CueActivityState(reading, at: .always()))
        }

        // 两件都落在等你上：数与 Cue 那一行同一份，格子是两格等你加一格今天做完的；第一件是 Cue 的提问，能"允许一次"
        var (tally, activity) = try await both()
        #expect(tally.managing.isEmpty && tally.waiting.count == 2)
        #expect(activity.managing == 0 && activity.waiting == 2 && activity.isLive)
        #expect(activity.cells == [.waiting, .waiting, .done])
        #expect(activity.lastDone?.title == "README 截图换成 Swift 版")
        let first = try #require(activity.first)
        #expect(first.title == "推送 v1.4 到 TestFlight" && first.detail == "Cue 请你允许推送代码" && first.open == DeepLink.cue.url)
        let allow = try #require(first.allow)
        #expect(allow.message == push.id && allow.choice == CueAsk.once)

        // 允许一次（实时活动在 App 进程里调的就是它）：发布回到在管，会话在问的接上来，只能打开
        try await rig.services.answerCueQuestion(allow.message, allow.choice)
        (tally, activity) = try await both()
        #expect(tally.managing.map(\.id) == ["task/\(release.id.uuidString)"] && tally.waiting.count == 1)
        #expect(activity.managing == 1 && activity.waiting == 1 && activity.cells == [.managing, .waiting, .done])
        #expect(activity.first == CueActivityState.Wait(
            title: "canvas-zoom", detail: "改锚点？", open: DeepLink.session(PiSessionState.recordID(sessionID: "zoom")).url, allow: nil))

        // 两件都做完、会话都结束：没有在管与等你，实时活动结束；格子只剩做完的
        try await workspace.toggle(canvas.id)
        try await workspace.toggle(release.id)
        try await recorder.update(sessionID: "zoom", state: .ended)
        try await recorder.update(sessionID: "testflight", state: .ended)
        (tally, activity) = try await both()
        #expect(tally.managing.isEmpty && tally.waiting.isEmpty)
        #expect(!activity.isLive && activity.first == nil && activity.cells == [.done, .done, .done])
    }
}
