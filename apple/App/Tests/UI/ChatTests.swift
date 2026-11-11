import CueStore
import Foundation
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct ChatTests {
    @Test func 没送到的话_看过以后行上仍留标记_与会话页同一个数() async throws {
        let app = TestApp()
        let store = app.services.store
        try await StateRecorder(store: store, hostID: "mac-fail").update(sessionID: "relay", state: .settled, title: "relay")
        let target = SendTarget(kind: .piSession, name: "relay", ref: "relay")
        let lost = try await store.requestDelivery("改完再跑一遍", to: target, on: "mac-fail", mode: .send)
        _ = try await store.requestDelivery("还在路上的一句", to: target, on: "mac-wait", mode: .send)
        func item() async throws -> SessionListItem { try #require(try await store.sessionPage(SessionQuery()).items.first) }
        #expect(try await item().undelivered(at: .always()) == 0)

        let executor = DeliveryExecutor(store: store, hostID: "mac-fail", onIssue: { _ in }) { _, _ in .failed(.verbatim("Pi 已经退出")) }
        try await executor.start()
        _ = try await eventually(store, { try $0.deliveryRequest(lost.id)?.isOpen }) { $0 == false }
        await executor.stop()

        let failed = try await item()
        #expect(failed.undelivered(at: .always()) == 1 && Chat.undeliveredNote(failed.undelivered(at: .always())) == "1 句没送到")
        #expect(try await SessionDigest.read(failed.id, sessionID: "relay", from: store).undelivered(at: .always()) == 1)

        app.services.settings.markSeen(failed.state, at: .now.addingTimeInterval(1))
        #expect(Workspace(services: app.services).shown(try await item()).undelivered == nil)
        #expect(try await item().undelivered(at: .always()) == 1)
    }
}
