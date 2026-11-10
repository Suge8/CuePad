#if os(macOS)
import CloudKit
@testable import CueStore
@testable import CueSync
import CueTestSupport
import CueText
import Foundation
import Synchronization
import Testing
@testable import CuePad

/// "手机"是第二个 Mac 进程（同 `AgentLibraryTests` 的经云同步），成功路径走新会话表单的 `Workspace.submitSession`，附件失败与重试走它写请求的 `AppServices.launchSession`。
@MainActor
@Suite(.releasesLibraries)
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
        defer { await recording.stop() }

        let shot = pngData(width: 12, height: 9)
        let key = try phone.services.store.files.store(shot)
        let draft = ComposerDraft(text: "看这张截图", files: [DraftFile(key: key, name: "")])
        let workspace = Workspace(services: phone.services)
        let project = try #require(try await phone.services.store.project(Project.defaultID))
        let place = ProjectFolders.launchPlaces(projects: [project], bindings: [], host: nil, workMac: TestApp.hostID).first
        var claimed: LaunchProgress.Claimed?
        workspace.submitSession(in: place, draft: draft, choice: AgentModelChoice(agents: [], agent: .pi, model: nil, thinking: nil)) { claimed = $1 }

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
        try await eventually("认领到新会话") { claimed != nil }
        let session = try #require(claimed).sessionID
        #expect(try await phone.services.store.hasAttachment(key))
        #expect(try Data(contentsOf: #require(mac.services.store.files.fileURL(for: key))) == shot)
        let first = try #require(mac.host.extensions[session]?.messages.first)
        #expect(first.text == "看这张截图")
        #expect(first.images.map(\.data) == [shot])
        await mac.services.executor.beginStop()()
    }

    @Test func 新会话附件到期还没传到Mac_写回失败_手机解锁可再开() async throws {
        let clock = ManualTiming()
        let mac = TestApp(timing: clock.timing)
        let phone = TestApp(timing: clock.timing, host: "phone")
        let fetches = Mutex(0)
        mac.sync.fetching.withLock {
            $0 = { _ in
                fetches.withLock { $0 += 1 }
                try await Task.sleep(for: .seconds(3600))  // 附件记录一直没同步过来
                throw FileFetchFailure.notSyncing
            }
        }
        try await mac.services.executor.start()
        defer {
            mac.pi.stop()
            mac.services.cancelBackgroundWork()
            phone.services.cancelBackgroundWork()
        }
        let missing = AttachmentKey.make(hash: String(repeating: "a", count: 64), format: "png")
        let draft = ComposerDraft(text: "看这张截图", files: [DraftFile(key: missing, name: "")])
        func launch(replacing previous: SessionLaunch?) async throws -> SessionLaunch {
            let launched = try await phone.services.launchSession(
                in: Project.defaultID, prompt: draft.stored, title: "CuePad", on: TestApp.hostID, card: nil, agent: .pi, intent: previous.map { .replacing($0.request) } ?? .new)
            let row = try #require(try await phone.services.store.syncRow(recordName: launched.request.uuidString.lowercased()))
            try await phone.services.store.markPushed([(row, Data(), clock.now)])
            return launched
        }
        func progress(_ launch: SessionLaunch) async throws -> LaunchProgress {
            try await awaitNext("会话启动进度", from: phone.services.store.observe({ try launch.progress(from: $0) }))
        }
        func phase(_ launch: SessionLaunch) async throws -> LaunchProgress.Phase { try await progress(launch).phase(at: phone.services.speech) }
        // 经服务器转一手：此刻服务器收下（拉到它的那台记下收下的时刻）
        func relay(_ id: UUID, from: TestApp, to: TestApp) async throws {
            let row = try #require(try await from.services.store.syncRow(recordName: id.uuidString.lowercased()))
            #expect(try await to.services.store.applyRemote([.save(row, systemFields: Data(), serverAt: clock.now)]).isEmpty)
        }

        let first = try await launch(replacing: nil)
        try await relay(first.request, from: phone, to: mac)
        try await eventually("Mac 在旁边取附件") { fetches.withLock { $0 } > 0 }
        guard case .sending = try await phase(first) else { Issue.record("发出后应是在路上"); return }
        #expect(try await phase(first).submission == .waiting, "在路上不重复提交")

        let request = try #require(try await mac.services.store.deliveryRequest(first.request))
        try await clock.sleeper()
        clock.advance(.seconds(try #require(request.dispatchDeadline).timeIntervalSince(clock.now)))
        let failed = try await mac.services.store.outcome(of: request)
        #expect(failed.failure == "附件到期还没传到这台 Mac，没有发出，可以重发")
        #expect(mac.host.calls.isEmpty)

        clock.advance(.seconds(DeliveryExecutor.retention.seconds + 1))
        let now = clock.now
        _ = try await mac.services.store.deleteCompletedDeliveries(
            before: now, claimCutoff: now, keptCutoff: now.addingTimeInterval(-DeliveryExecutor.keptRetention))
        #expect(try await mac.services.store.deliveryRequest(first.request) != nil)
        try await relay(first.request, from: mac, to: phone)
        #expect(try await phase(first) == .failed(.reported("附件到期还没传到这台 Mac，没有发出，可以重发")))
        #expect(try await phase(first).submission == .safe, "明确失败允许安全替换")

        let second = try await launch(replacing: first)
        let after = try await phone.services.store.deliveryRequests()
        #expect(after.map(\.id) == [second.request])
        #expect(after.first?.launch?.prompt == draft.stored)
        #expect(try await phase(second).submission == .waiting, "再次发出后不重复提交")
        #expect(try await phase(first) == .missing)
        #expect(try await phase(first).submission == .confirm, "查不到结果不能冒充可安全重试")
        await mac.services.executor.beginStop()()
    }
}
#endif
