#if os(macOS)
import CueTestSupport
import Foundation
import SwiftUI
import Testing
@testable import CuePad
@testable import CueStore

@Suite(.pinnedPi)
@MainActor
struct CuePatrolTests {
    @Test func 唯一在做的会话没说话就退出_Cue随后巡视() async throws {
        let rig = try await CueHostTests.Rig(patrolAfter: Self.patrolAfter, prepare: CueHostTests.Rig.handOverWork)
        let store = rig.store
        let session = try await rig.app.host.connect("quiet", cwd: rig.folder.path, busy: true)
        try await eventually("会话记进库") { try await store.sessions(matching: "quiet").first != nil }

        let workspace = Workspace(services: rig.services)
        workspace.cue.draft = ComposerDraft(text: "你好")
        await workspace.speak(to: .cue, from: Bindable(workspace.cue).draft) { $0.stored }.value
        try await rig.message(.cue, containing: "收到：你好")

        let exited = Date.now
        session.close(bye: "quit")
        try await eventually("会话的记录删掉") { try await store.sessions(matching: "quiet").isEmpty }
        try await idle(rig)
        try await eventually("退出之后巡视") {
            try await store.cueMessages().contains { $0.author == .known(.cue) && $0.text.contains("巡视了一圈") && $0.createdAt > exited }
        }
        await rig.stop()
    }

    /// 手机上的软删除带着更早的修改时间，早于这台 Mac 上之后改过的卡片。
    @Test func 唯一在做的任务经同步删掉_Cue随后巡视() async throws {
        let rig = try await CueHostTests.Rig(patrolAfter: Self.patrolAfter, prepare: CueHostTests.Rig.handOverWork)
        let store = rig.store
        let project = try #require(try await store.projects().first)
        let task = try await store.createTask("在别的 Mac 上开工", in: project.id)
        _ = try await store.requestLaunch(PiLaunch(project: project.id, prompt: nil, token: "elsewhere"), title: task.body, on: "mac-b", card: task.id)
        let started = try #require(try await store.card(task.id))
        try await Task.sleep(for: .milliseconds(5))  // 这台 Mac 上之后改的卡片：修改时间晚于手机上那次删除
        _ = try await store.createCard(in: project.id, body: "随手记")

        let workspace = Workspace(services: rig.services)
        workspace.cue.draft = ComposerDraft(text: "你好")
        await workspace.speak(to: .cue, from: Bindable(workspace.cue).draft) { $0.stored }.value
        try await rig.message(.cue, containing: "收到：你好")

        #expect(try await store.cueBoardActive())  // 别的 Mac 上正在开会话的那件事还在做
        var deleted = try #require(try await store.syncRow(recordName: task.id.uuidString.lowercased()))
        let deletedAt = SQLValue.int(Int64((started.modifiedAt.timeIntervalSince1970 * 1000).rounded()) + 1)
        deleted.fields["deletedAt"] = deletedAt
        deleted.fields["modifiedAt"] = deletedAt
        let synced = Date.now
        #expect(try await store.applyRemote([.save(deleted, systemFields: Data())]).isEmpty)
        #expect(try await store.card(task.id)?.deletedAt != nil)
        try await idle(rig)
        try await eventually("删掉之后巡视") {
            try await store.cueMessages().contains { $0.author == .known(.cue) && $0.text.contains("巡视了一圈") && $0.createdAt > synced }
        }
        await rig.stop()
    }

    private static let patrolAfter = Duration.seconds(60)

    /// 你最后一句之后空闲够久（冷巡视的时长）：不真等，跳过去。
    private func idle(_ rig: CueHostTests.Rig) async throws {
        let lastYou = try #require(try await rig.store.cueLastYou()?.said)
        rig.jump(to: lastYou + Self.patrolAfter.seconds)
    }
}
#endif
