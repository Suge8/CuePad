import CueStore
import Foundation
import Testing
@testable import CuePad

@MainActor
@Suite(.releasesLibraries)
struct AwaitingReplyTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }

    @Test func 出错留给你回后再说一句_看板当场回到推进中_点卡进卡上的会话() async throws {
        let workspace = Workspace(services: rig.services)
        _ = try await store.updateCueProfile {
            $0.hostID = "mac-cue"
            $0.enabledAt = .now
        }
        try await store.recordMacPresence(host: "mac-cue") { true }
        let recorder = try await rig.runtimeRecorder(on: "mac-a")
        try await recorder.update(
            sessionID: "billing", state: .error, detail: "connection refused", title: "billing",
            times: SessionTimes(stateSince: .now.addingTimeInterval(-600), busySince: nil))
        let parent = try await store.createTask("导入旧数据")
        _ = try await store.createTask("先读一遍", under: parent.id)
        let second = try await store.createTask("再导进去", under: parent.id)
        try await store.bindSession("billing", to: second.id)
        _ = try await store.leaveToYou("billing")
        let idle = try await store.createTask("还没开始的")

        var board = try await TaskBoard.read(from: store)
        #expect(board.held.map(\.session.sessionID) == ["billing"] && board.held.first?.item?.id == parent.id)
        #expect(board.held.first?.item?.agent?.state.sessionID == "billing")

        let session = try #require(board.held.first?.item?.agent?.state)
        let box = rig.services.settings.replyDraftBinding(for: session.id)
        box.wrappedValue = ComposerDraft(text: "网络好了，接着做")
        await workspace.speak(to: .session(session, mode: .send), from: box) { $0.text }.value

        board = try await TaskBoard.read(from: store)
        #expect(board.held.isEmpty && board.count(.waiting) == 0)
        let work = try #require(board.advancing.first { $0.item?.id == parent.id })
        var pulse = workspace.pulse(of: work.agent)
        #expect(pulse.tier == .running && pulse.word == nil)

        try await recorder.update(sessionID: "billing", state: .thinking, times: SessionTimes(stateSince: .now, busySince: .now))
        board = try await TaskBoard.read(from: store)
        pulse = workspace.pulse(of: try #require(board.advancing.first { $0.item?.id == parent.id }).agent)
        #expect(pulse.shown?.status == .working(.thinking))

        let item = try #require(board.advancing.first { $0.item?.id == parent.id }?.item)
        workspace.enter(item.task, session: item.agent?.state)
        #expect(workspace.shownSessions.map(\.sessionID) == ["billing"] && workspace.openTask == nil)
        let todo = try #require(board.todo.first { $0.id == idle.id })
        workspace.enter(todo.task, session: todo.agent?.state)
        #expect(workspace.openTask?.task == idle.id)
    }
}
