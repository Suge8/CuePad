#if os(macOS)
import CueTestSupport
import Foundation
import SwiftUI
import Testing
@testable import CuePad
@testable import CueStore

/// 值班的 Cue 在看板空下来之后照常巡视（真 Pi 当大脑，同 `CueHostTests`）。
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: realPi.path), "需要 ~/.local/bin/pi"), .timeLimit(.minutes(2)))
@MainActor
struct CuePatrolTests {
    /// 终端里开着的会话一句话没说就退出了（没有会话文件：记录删掉，不算会话的动静）。它原是唯一在做的事，看板就空了：
    /// 你跟 Cue 说过话之后空闲够久，Cue 巡视一次。
    @Test func 唯一在做的会话没说话就退出_Cue随后巡视() async throws {
        let rig = try await CueHostTests.Rig(patrolAfter: .seconds(2))
        let store = rig.store
        let session = try await rig.app.host.connect("quiet", cwd: rig.folder.path, busy: true)
        try await eventually("会话记进库") { try await store.sessions(matching: "quiet").first != nil }

        let workspace = Workspace(services: rig.services)
        workspace.cue.draft = ComposerDraft(text: "你好")
        await workspace.speak(to: .cue, from: Bindable(workspace.cue).draft) { try $0.stored(in: store.files) }?.value
        try await rig.message(.cue, containing: "收到：你好")

        let exited = Date.now
        session.close(bye: "quit")
        try await eventually("会话的记录删掉") { try await store.sessions(matching: "quiet").isEmpty }
        try await eventually("退出之后巡视", timeout: .seconds(15)) {
            try await store.cueMessages().contains { $0.author == .known(.note) && $0.text.contains("巡视了一圈") && $0.createdAt > exited }
        }
        await rig.stop()
    }

    /// 唯一在做的事是一件正在别的 Mac 上开会话的任务；你在手机上删了它，经同步到这台 Mac（软删除带着手机上更早的修改时间，
    /// 早于这台 Mac 上之后改过的卡片）。看板空了：你跟 Cue 说过话之后空闲够久，Cue 巡视一次。
    @Test func 唯一在做的任务经同步删掉_Cue随后巡视() async throws {
        let rig = try await CueHostTests.Rig(patrolAfter: .seconds(2))
        let store = rig.store
        let project = try #require(try await store.projects().first)
        let task = try await store.createTask("在别的 Mac 上开工", in: project.id)
        _ = try await store.requestLaunch(PiLaunch(project: project.id, prompt: nil, token: "elsewhere"), title: task.body, on: "mac-b", card: task.id)
        try await Task.sleep(for: .milliseconds(5))  // 这台 Mac 上之后改的卡片：修改时间晚于手机上那次删除
        _ = try await store.createCard(in: project.id, body: "随手记")

        let workspace = Workspace(services: rig.services)
        workspace.cue.draft = ComposerDraft(text: "你好")
        await workspace.speak(to: .cue, from: Bindable(workspace.cue).draft) { try $0.stored(in: store.files) }?.value
        try await rig.message(.cue, containing: "收到：你好")

        #expect(try await store.cueBoardActive())  // 别的 Mac 上正在开会话的那件事还在做
        var deleted = try #require(try await store.syncRow(recordName: task.id.uuidString.lowercased()))
        let deletedAt = SQLValue.int(Int64((task.modifiedAt.timeIntervalSince1970 * 1000).rounded()) + 1)
        deleted.fields["deletedAt"] = deletedAt
        deleted.fields["modifiedAt"] = deletedAt
        let synced = Date.now
        #expect(try await store.applyRemote([.save(deleted, systemFields: Data())]).isEmpty)
        #expect(try await store.card(task.id)?.deletedAt != nil)
        try await eventually("删掉之后巡视", timeout: .seconds(15)) {
            try await store.cueMessages().contains { $0.author == .known(.note) && $0.text.contains("巡视了一圈") && $0.createdAt > synced }
        }
        await rig.stop()
    }
}
#endif
