#if os(macOS)
import CueTestSupport
import Foundation
import Testing
@testable import CuePad
@testable import CueStore

extension DeliveryMigrationTests {
    @Test(arguments: [DeliveryMode.send, .start, .command], [false, true])
    func 升级前在途投送_送达后关联原卡片_升级后明确解绑仍优先(mode: DeliveryMode, task: Bool) async throws {
        let app = TestApp()
        defer {
            for ext in app.host.extensions.values { ext.close(bye: "quit") }
            app.pi.stop(); app.services.cancelBackgroundWork()
        }
        try await app.services.store.setDirectory(app.directory.path, for: Project.defaultID)
        let workspace = Workspace(services: app.services)
        let card = try await task ? workspace.createTask("升级中的任务", in: Project.defaultID) : app.services.store.createCard(body: "升级中的灵感")
        let content = switch mode {
        case .start: PiLaunch(project: Project.defaultID, prompt: card.body, token: "legacy-launch").stored
        case .command: "/shout \(card.body)"
        default: card.body
        }
        await workspace.speak(content, to: .session(
            SendTarget(kind: .piSession, name: "投送目标", ref: mode == .start ? nil : "atlas"),
            host: TestApp.hostID, mode: mode, card: card.id)).value
        let pending = try #require(try await app.services.store.deliveryRequests().first)
        try seedSchema92(app)
        let services = app.relaunch(), store = services.store
        if mode != .start { try await app.host.connect("atlas", cwd: app.directory.path, hosted: true) }
        let changes = app.pi.changes()
        let recording = Task { try await services.consumePiChanges(changes) }
        defer { recording.cancel() }
        try await services.executor.start()
        let migrated = try #require(try await store.deliveryRequest(pending.id))
        #expect(try await store.outcome(of: migrated).status == .known(.succeeded))
        let sessionID = mode == .start ? "new-legacy-launch" : "atlas"
        #expect(try await store.card(card.id)?.piSessionID == sessionID)
        #expect(try await store.card(card.id)?.isTask == task)
        #expect(try await store.piSessions(sessionIDs: [sessionID])[sessionID]?.state.createdForTaskID == nil)
        if task {
            try await store.unbindSession(from: card.id)
            // 与发送执行器相同的回执入口：升级后的明确解绑不能被迁移的旧请求重放。
            try await store.linkDeliveredCard(migrated, toSession: sessionID)
            #expect(try await store.card(card.id)?.piSessionID == nil)
        }
        await services.executor.beginStop()()
    }

    @Test(arguments: [DeliveryMode.send, .start, .command])
    func 九十二版已送达关联_升级后正文重放保留关联且不授予结束权限(mode: DeliveryMode) async throws {
        let app = TestApp()
        defer {
            for ext in app.host.extensions.values { ext.close(bye: "quit") }
            app.pi.stop(); app.services.cancelBackgroundWork()
        }
        #expect(CueStore.schemaVersion(of: app.databaseURL) == CueStore.supportedSchemaVersions.upperBound && CueStore.peerFloor == 93)
        try await app.services.store.setDirectory(app.directory.path, for: Project.defaultID)
        let workspace = Workspace(services: app.services), original = app.services.store
        let card = try await workspace.createTask("准备发布", in: Project.defaultID)
        if mode != .start { try await app.host.connect("atlas", cwd: app.directory.path, hosted: true) }
        let content = switch mode {
        case .start: PiLaunch(project: Project.defaultID, prompt: card.body, token: "legacy-settled").stored
        case .command: "/shout 准备发布"
        default: card.body
        }
        await workspace.speak(content, to: .session(
            SendTarget(kind: .piSession, name: "会话", ref: mode == .start ? nil : "atlas"), host: TestApp.hostID, mode: mode, card: card.id)).value
        let request = try #require(try await original.deliveryRequests().first)
        let changes = app.pi.changes()
        let recording = Task { try await app.services.consumePiChanges(changes) }
        try await app.services.executor.start()
        #expect(try await original.outcome(of: request).status == .known(.succeeded))
        let sessionID = mode == .start ? "new-legacy-settled" : "atlas"
        #expect(try await original.card(card.id)?.piSessionID == sessionID)
        await app.services.executor.beginStop()()
        recording.cancel()
        do { try await recording.value } catch is CancellationError {}
        try seedSchema92(app)
        let services = app.relaunch(), store = services.store
        #expect(CueStore.schemaVersion(of: app.databaseURL) == CueStore.supportedSchemaVersions.upperBound)
        var edited = try #require(try await store.syncRow(recordName: card.id.uuidString.lowercased()))
        let pending = try #require(try await store.syncRow(recordName: request.id.uuidString.lowercased()))
        // 同一旧请求对应的未兑现正文副本；迁移必须保留另一端已经兑现的关联。
        edited.fields["piSessionID"] = .null
        edited.fields["sessionBindingRevision"] = pending.fields["sessionBindingRevision"]
        edited.fields["body"] = .text("准备发布\n手机补充")
        edited.fields["modifiedAt"] = .int(edited.modifiedAt + 1_000)
        #expect(try await store.applyRemote([.save(edited, systemFields: Data())]).isEmpty)
        #expect(try await store.card(card.id)?.body == "准备发布\n手机补充")
        #expect(try await store.card(card.id)?.piSessionID == sessionID)
        try await Workspace(services: services).complete(card.id)
        #expect(try await store.deliveryRequests().filter { $0.mode == .known(.end) }.isEmpty)
        #expect(try await store.piSessions(sessionIDs: [sessionID])[sessionID]?.state.createdForTaskID == nil)
    }

    private func seedSchema92(_ app: TestApp) throws {
        try RawDB(app.databaseURL).exec("""
            UPDATE deliveryRequests SET content = json_remove(content, '$.createdForTaskID') WHERE mode = 'start';
            ALTER TABLE cards DROP COLUMN sessionBindingRevision;
            ALTER TABLE deliveryRequests DROP COLUMN sessionBindingRevision;
            DROP INDEX piSessionStates_createdForTaskID;
            ALTER TABLE piSessionStates DROP COLUMN createdForTaskID;
            PRAGMA user_version = 92;
            """)
    }

}
#endif
