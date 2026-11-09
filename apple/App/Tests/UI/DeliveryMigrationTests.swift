#if os(macOS)
import CueTestSupport
import CueText
import Foundation
import SwiftUI
import Testing
@testable import CuePad
@testable import CueStore

/// 旧库升级：旧 failed 不能冒充新版本明确未交出的 not_delivered，原原因不能被猜写；升级前已上传的待派发请求照常到期。
@MainActor
struct DeliveryMigrationTests {
    private func say(in app: TestApp) async throws -> DeliveryRequest {
        await Workspace(services: app.services).speak("上传结果", to: .session(
            SendTarget(kind: .piSession, name: "发布", ref: "atlas"), host: TestApp.hostID, mode: .send, card: nil)).value
        return try #require(try await app.services.store.deliveryRequests().first)
    }

    @Test(arguments: [true, false])
    func 重开旧库升级_保留原原因_未知不重发_正规化结果待上传(claimed: Bool) async throws {
        let app = TestApp(), request = try await say(in: app)
        let row = try #require(try await app.services.store.syncRow(recordName: request.id.uuidString.lowercased()))
        #expect(try await app.services.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        let db = RawDB(app.services.location.databaseURL)
        try db.restoreVersion90()
        let handled = claimed ? "'\(TestApp.hostID)'" : "NULL"
        let reason = ShownText.verbatim("原来的失败原因").stored
        try db.exec("""
            UPDATE deliveryRequests SET status = 'failed', handledBy = \(handled), failure = '\(reason)', completedAt = modifiedAt;
            UPDATE syncRecords SET pushedModifiedAt = (SELECT modifiedAt FROM deliveryRequests WHERE id = recordName);
            DROP TRIGGER piSessionStates_writeSeq_update;
            ALTER TABLE piSessionStates DROP COLUMN bootID;
            ALTER TABLE macPresence DROP COLUMN bootID;
            ALTER TABLE cueState DROP COLUMN hostID;
            ALTER TABLE cueState DROP COLUMN bootID;
            CREATE TRIGGER piSessionStates_writeSeq_update AFTER UPDATE OF state ON piSessionStates BEGIN SELECT 1; END;
            ALTER TABLE deliveryRequests DROP COLUMN deadlineAt;
            DROP TABLE activityDestinations;
            ALTER TABLE sessionViewers DROP COLUMN sessionIDs;
            ALTER TABLE sessionViewers ADD COLUMN sessionID TEXT;
            PRAGMA user_version = 82;
            """)
        let services = app.relaunch(), store = services.store
        defer { services.cancelBackgroundWork() }
        let migrated = try #require(try await store.deliveryRequest(request.id))
        #expect(migrated.status == (claimed ? .known(.unconfirmed) : .known(.failed)))
        #expect(migrated.reason?.text == "原来的失败原因")
        #expect(try await store.pendingSync(among: [row.id]).saves.map(\.id) == [row.id])
        let workspace = Workspace(services: services)
        await workspace.resend(.request(migrated), restoringInto: services.settings.replyDraftBinding(for: UUID())).value
        #expect((workspace.notice?.isError == true) == claimed)
    }

    /// 升级前已传上去、还在等派发的请求，发送方没记下服务器收下的时刻：升级按写下的时刻补上，到期照常转未确认，不一直显示已发出。
    @Test func 升级前已传上去的待派发请求_升级后补上锚点_到期转未确认() async throws {
        let phone = TestApp(host: "phone"), request = try await say(in: phone)
        let row = try #require(try await phone.services.store.syncRow(recordName: request.id.uuidString.lowercased()))
        try await phone.services.store.markPushed([(row, Data(), nil)])  // 旧版的上传回执不记收下时刻
        let lapsed = Int((DeliveryRequest.phaseLimit + Speech.receiptLimit + 60) * 1000)
        try RawDB(phone.services.location.databaseURL).restoreVersion90()
        try RawDB(phone.services.location.databaseURL).exec("""
            UPDATE deliveryRequests SET createdAt = createdAt - \(lapsed), serverAt = NULL;
            PRAGMA user_version = 89;
            """)
        let services = phone.relaunch(), store = services.store
        defer { services.cancelBackgroundWork() }
        let migrated = try #require(try await store.deliveryRequest(request.id))
        #expect(migrated.serverAt == migrated.createdAt)
        #expect(Speech.trip(migrated, at: services.speech).unconfirmedReason != nil)
    }
}
#endif
