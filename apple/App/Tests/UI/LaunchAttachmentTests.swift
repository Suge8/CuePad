#if os(macOS)
import CloudKit
@testable import CueStore
@testable import CueSync
import CueTestSupport
import CueText
import Foundation
import SwiftUI
import Synchronization
import Testing
@testable import CuePad

/// 带附件的那句话一定走到终态：手机开新会话、第一句带新选的截图，图随请求传上去、Mac 开会话时交给 Agent 的就是这张图；
/// 附件到派发期限还没传到 Mac，Mac 写回明确失败（说明在等什么），手机按失败显示、可以重发。
/// "手机"是第二个 Mac 进程（同 `AgentLibraryTests` 的经云同步），开会话从它的工作区走（`Workspace.startSession`，手机的新会话输入框调的同一条 `launchSession`）。
@MainActor
struct LaunchAttachmentTests {
    @Test func 手机新会话第一句带新选截图_图传上去_Mac开会话时Agent收到这张图() async throws {
        let cloud = SimulatedCloud([CKRecord.peerFloor(CueStore.peerFloor)])
        let mac = TestApp(sync: .built { CloudSync(store: $0) { cloud } })
        let phone = TestApp(sync: .built { CloudSync(store: $0) { cloud } }, host: "mac-phone")
        let folder = mac.directory.appending(path: "work/cuepad", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await mac.services.store.setDirectory(folder.path, for: Project.defaultID)
        for side in [mac, phone] { side.services.startSync() }
        defer {
            for ext in mac.host.extensions.values { ext.close(bye: "quit") }
            mac.pi.stop()
            for side in [mac, phone] { side.services.cancelBackgroundWork() }
        }
        try await mac.services.executor.start()
        let changes = mac.pi.changes()
        let recording = Task { try await mac.services.consumePiChanges(changes) }
        defer { recording.cancel() }

        // 新选的截图：存进手机的附件目录，草稿里只有它的引用（`DraftFile`）
        let shot = pngData(width: 12, height: 9)
        let key = try phone.services.store.files.store(shot)
        let draft = ComposerDraft(text: "看这张截图", files: [DraftFile(key: key, name: "")])
        let workspace = Workspace(services: phone.services)
        let opening = Task {
            try await workspace.startSession(
                in: Project.defaultID, prompt: draft.stored, title: "CuePad", on: TestApp.hostID, agent: .pi) { _ in }
        }
        defer { opening.cancel() }

        let requests = try await eventually(phone.services.store, { try $0.deliveryRequests() }) { !$0.isEmpty }
        let request = try #require(requests.first)
        try #require(try await phone.services.store.hasAttachment(key))
        await phone.services.upload(request.id)
        await phone.services.syncNow()
        await mac.services.syncNow()
        #expect(try await mac.services.store.outcome(of: request).status == .known(.succeeded))
        let sessions = try await eventually(mac.services.store, { try $0.allPiSessionStates() }) { $0.contains { $0.launchToken != nil } }
        for session in sessions { await mac.services.upload(session.id) }
        await mac.services.upload(request.id)
        await mac.services.syncNow()
        await phone.services.syncNow()
        let session = try await opening.value
        #expect(try await phone.services.store.hasAttachment(key))
        #expect(try Data(contentsOf: #require(mac.services.store.files.fileURL(for: key))) == shot)
        let first = try #require(mac.host.extensions[session]?.messages.first)
        #expect(first.text == "看这张截图")
        #expect(first.images.map(\.data) == [shot])
        await mac.services.executor.beginStop()()
    }

    @Test func 附件到期还没传到Mac_写回失败_手机可重发() async throws {
        let clock = ManualTiming()
        let app = TestApp(timing: clock.timing)
        let services: AppServices = app.services
        let phone = TestApp(timing: clock.timing, host: "phone")
        let atlas = try await app.host.connect("atlas", cwd: "/work/atlas")
        let fetches = Mutex(0)
        app.sync.fetching.withLock {
            $0 = { _ in
                fetches.withLock { $0 += 1 }
                try await Task.sleep(for: .seconds(3600))  // 附件记录一直没同步过来
                throw FileFetchFailure.notSyncing
            }
        }
        try await services.executor.start()
        defer {
            atlas.close(bye: "quit")
            app.pi.stop()
            services.cancelBackgroundWork()
            phone.services.cancelBackgroundWork()
        }
        let workspace = Workspace(services: phone.services)
        let missing = AttachmentKey.make(hash: String(repeating: "a", count: 64), format: "png")
        var box = ComposerDraft(text: "看这张截图", files: [DraftFile(key: missing, name: "")])
        let binding = Binding(get: { box }, set: { box = $0 })
        let listener = Listener.session(SendTarget(kind: .piSession, name: "atlas", ref: "atlas"), host: TestApp.hostID, mode: .send, card: nil)
        await workspace.speak(to: listener, from: binding) { $0.stored }.value
        let request = try #require(try await phone.services.store.deliveryRequests().first)
        let pending = try #require(try await phone.services.store.syncRow(recordName: request.id.uuidString.lowercased()))
        #expect(try await services.store.applyRemote([.save(pending, systemFields: Data())]).isEmpty)
        let deadline = try #require(request.deadlineAt)

        try await eventually("Mac 在旁边取附件") { fetches.withLock { $0 } > 0 }
        #expect(Said.request(request).trip(at: services.speech).inTransit)

        await clock.waitForSleeper()
        clock.advance(.seconds(deadline.timeIntervalSince(clock.now)))
        let failed = try await services.store.outcome(of: request)
        #expect(failed.status == .known(.failed))
        #expect(failed.failure == "附件到期还没传到这台 Mac，没有发出，可以重发")
        let receipt = try #require(try await services.store.syncRow(recordName: request.id.uuidString.lowercased()))
        #expect(try await phone.services.store.applyRemote([.save(receipt, systemFields: Data())]).isEmpty)
        let received = try #require(try await phone.services.store.deliveryRequest(request.id))
        #expect(Said.request(received).trip(at: phone.services.speech).failure != nil)
        #expect(atlas.messages.isEmpty)

        await workspace.resend(.request(received), restoringInto: binding).value
        #expect(workspace.notice?.isError != true)
        let after = try await phone.services.store.deliveryRequests()
        #expect(after.count == 1 && after[0].id != request.id && after[0].content == request.content)
        await services.executor.beginStop()()
    }
}
#endif
