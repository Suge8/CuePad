#if os(macOS)
import CueTestSupport
import CueText
import Foundation
import SwiftUI
import Testing
@testable import CuePad
@testable import CueStore

/// #43 的格式边界：旧 failed 不能冒充新版本明确未交出的 not_delivered，原原因不能被猜写。
@MainActor
struct DeliveryMigrationTests {
    private func say(in app: TestApp) async throws -> DeliveryRequest {
        await Workspace(services: app.services).speak("上传结果", to: .session(
            SendTarget(kind: .piSession, name: "发布", ref: "atlas"), host: TestApp.hostID, mode: .send, card: nil)).value
        return try #require(try await app.services.store.deliveryRequests().first)
    }

    @Test(arguments: [("failed", true), ("failed", false), ("not_delivered", true)])
    func 升级后第一次拉到旧失败也按领取事实收口_新明确失败不混入未知(raw: String, claimed: Bool) async throws {
        let sender = TestApp(), receiver = TestApp(), store = receiver.services.store
        let request = try await say(in: sender)
        var row = try #require(try await sender.services.store.syncRow(recordName: request.id.uuidString.lowercased()))
        row.fields["status"] = .text(raw)
        row.fields["handledBy"] = claimed ? .text(TestApp.hostID) : .null
        row.fields["failure"] = .text(ShownText.verbatim("原样保留的错误").stored)
        row.fields["completedAt"] = row.fields["modifiedAt"]
        #expect(try await store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        let current = try #require(try await store.deliveryRequest(request.id))
        let uncertain = raw == "failed" && claimed
        #expect(current.status == (uncertain ? .known(.unconfirmed) : .known(.failed)))
        #expect(current.failureReason?.text == "原样保留的错误")
        let canonical = try #require(try await store.syncRow(recordName: row.id))
        #expect(canonical.fields["status"] == .text(uncertain ? "unconfirmed" : "not_delivered"))
        if raw == "failed" {
            #expect(try await store.pendingSync(among: [row.id]).saves.map(\.id) == [row.id])
        }
        let workspace = Workspace(services: receiver.services)
        await workspace.resend(.request(current), restoringInto: receiver.services.settings.replyDraftBinding(for: UUID())).value
        if uncertain {
            #expect(workspace.notice?.isError == true)
            #expect(try await store.deliveryRequests().map(\.id) == [request.id])
        } else {
            #expect(workspace.notice?.isError != true)
            let renewed = try await store.deliveryRequests()
            #expect(renewed.count == 1 && renewed.first?.id != request.id)
        }
        sender.services.cancelBackgroundWork(); receiver.services.cancelBackgroundWork()
    }

    @Test func 迟到的旧领取失败不能被较新未送达快照抹掉_仍不得安全重发() async throws {
        let sender = TestApp(), receiver = TestApp(), store = receiver.services.store
        let request = try await say(in: sender)
        var old = try #require(try await sender.services.store.syncRow(recordName: request.id.uuidString.lowercased()))
        old.fields["status"] = .text("failed")
        old.fields["handledBy"] = .text(TestApp.hostID)
        old.fields["failure"] = .text(ShownText.verbatim("旧宿主的原始错误").stored)
        var newer = old
        newer.fields["status"] = .text("not_delivered")
        newer.fields["modifiedAt"] = .int(old.modifiedAt + 60_000)
        #expect(try await store.applyRemote([.save(newer, systemFields: Data())]).isEmpty)
        // 本机的新写回尚未上传，不能让修改时间的胜负抹掉旧宿主曾领取的证据。
        try RawDB(receiver.services.location.databaseURL).exec("UPDATE deliveryRequests SET modifiedAt = modifiedAt + 1")
        #expect(try await store.applyRemote([.save(old, systemFields: Data())]).isEmpty)
        let current = try #require(try await store.deliveryRequest(request.id))
        #expect(current.status == .known(.unconfirmed))
        #expect(current.failureReason?.text == "旧宿主的原始错误")
        let workspace = Workspace(services: receiver.services)
        await workspace.resend(.request(current), restoringInto: receiver.services.settings.replyDraftBinding(for: UUID())).value
        #expect(workspace.notice?.isError == true)
        #expect(try await store.deliveryRequests().map(\.id) == [request.id])
        sender.services.cancelBackgroundWork(); receiver.services.cancelBackgroundWork()
    }

    @Test(arguments: [true, false])
    func 重开旧库升级_保留原原因_未知不重发_正规化结果待上传(claimed: Bool) async throws {
        let app = TestApp(), request = try await say(in: app)
        let row = try #require(try await app.services.store.syncRow(recordName: request.id.uuidString.lowercased()))
        #expect(try await app.services.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        let db = RawDB(app.services.location.databaseURL)
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
            PRAGMA user_version = 82;
            """)
        let services = app.relaunch(), store = services.store
        defer { services.cancelBackgroundWork() }
        let migrated = try #require(try await store.deliveryRequest(request.id))
        #expect(migrated.status == (claimed ? .known(.unconfirmed) : .known(.failed)))
        #expect(migrated.failureReason?.text == "原来的失败原因")
        #expect(try await store.pendingSync(among: [row.id]).saves.map(\.id) == [row.id])
        let workspace = Workspace(services: services)
        await workspace.resend(.request(migrated), restoringInto: services.settings.replyDraftBinding(for: UUID())).value
        #expect((workspace.notice?.isError == true) == claimed)
    }
}
#endif
