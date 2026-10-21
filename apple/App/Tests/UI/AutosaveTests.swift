import CueStore
import Testing
@testable import CuePad

/// 自动保存：编辑器里停手一小会儿，正文就写进库，不用离开页面。
struct AutosaveTests {
    @Test func 编辑正文停手后写进库() async throws {
        let app = TestApp()
        let store = app.services.store
        let card = try await store.createCard(body: "续费域名")
        let editing = CardEditing(card, workspace: Workspace(services: app.services))

        editing.changed("续费域名\n顺便把证书也续了")

        _ = try await eventually(store, { try $0.card(card.id)?.body }) { $0 == "续费域名\n顺便把证书也续了" }
        withExtendedLifetime(editing) {}
    }
}
