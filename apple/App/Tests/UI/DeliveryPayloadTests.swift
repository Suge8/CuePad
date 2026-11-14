#if os(macOS)
import CueStore
@testable import CueSync
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

@MainActor
@Suite(.releasesLibraries)
struct DeliveryPayloadTests {
    @Test func 同步已读出的旧payload被撤回后不再交出_下一句仍正常送达() async throws {
        let cloud = ReceiptTests.WeakCloud()
        let phone = TestApp(sync: .built { CloudSync(store: $0) { cloud } }, host: "phone")
        let mac = TestApp(sync: .built { CloudSync(store: $0) { cloud } })
        let ext = try await mac.host.connect("atlas", cwd: mac.directory.path)
        defer {
            ext.close(bye: "quit"); mac.bridge.stop()
            phone.services.cancelBackgroundWork(); mac.services.cancelBackgroundWork()
        }
        let recorder = try await mac.runtimeRecorder(on: TestApp.hostID)
        try await recorder.update(sessionID: "atlas", state: .settled)
        let session = try #require(try await mac.services.store.allSessionStates().first)
        phone.services.startSync(); mac.services.startSync()
        try await eventually("两端同步就绪") {
            phone.services.syncing.state.status == .idle && phone.services.syncing.state.reconciled
                && mac.services.syncing.state.status == .idle && mac.services.syncing.state.reconciled
        }
        try await mac.services.executor.start()
        // 用独立 SQLite 写者精确落在第一次发送登记之前，等价于尚未交出的 pending 被原子撤回。
        // 只撤回指定内容，后续正常请求不受这个故障影响。
        try RawDB(phone.services.location.databaseURL).exec("""
            CREATE TRIGGER withdraw_before_send BEFORE INSERT ON syncRecords
            WHEN NEW.recordType = 'deliveryRequests' AND NEW.sentModifiedAt IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM syncRecords WHERE recordName = NEW.recordName)
            BEGIN
              DELETE FROM deliveryRequests WHERE id = NEW.recordName AND status = 'pending' AND content = '已经撤回的旧话';
            END;
            """)
        let workspace = Workspace(services: phone.services)
        await workspace.speak("已经撤回的旧话", to: .session(session, mode: .send)).value
        try await eventually("旧话在交出前撤回") { try await phone.services.store.deliveryRequests().allSatisfy { $0.content != "已经撤回的旧话" } }
        await workspace.speak("只执行这句新话", to: .session(session, mode: .send)).value
        let next = try #require(try await phone.services.store.deliveryRequests().first { $0.content == "只执行这句新话" })
        await mac.services.syncing.syncNow()
        try await eventually("新话到达 Mac") { try await mac.services.store.deliveryRequest(next.id) != nil }
        #expect(try await mac.services.store.outcome(of: next).status == .known(.succeeded))
        #expect(ext.messages.map(\.text) == ["只执行这句新话"])
        await mac.services.executor.beginStop()()
    }
}
#endif
