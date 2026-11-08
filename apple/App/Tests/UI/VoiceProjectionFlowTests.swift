#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

@MainActor struct VoiceProjectionFlowTests {
    @Test func 未保存原话可辨认_截断不改恢复正文() async throws {
        let app = TestApp(), services = app.services!, store = services.store
        let host = TestApp.hostID
        try await store.updateCueProfile { $0.enabledAt = .now; $0.hostID = host }
        let fixture = VoiceFlowFixture(services)
        defer { fixture.call.hangUp(); services.cancelBackgroundWork() }
        try await fixture.connect()
        let db = RawDB(app.databaseURL)
        try db.exec("CREATE TRIGGER voice_preview_failure BEFORE INSERT ON cueMessages WHEN NEW.author = 'you' BEGIN SELECT RAISE(FAIL, 'preview flow write failure'); END")
        let original = String(repeating: "核对\"手机\"与桌面端\n", count: 120) + "末尾约束必须保留"
        fixture.received?(.success(.delegation(.init(id: "original", turn: nil, text: original))))
        try await eventually("原请求保存失败") { fixture.call.requests.first?.failure != nil }
        let projection = try services.voice.macProjection(fixture.call)
        let request = try #require(projection.requests.first)
        let preview = try #require(request.preview)
        #expect(!preview.text.isEmpty && original.hasPrefix(preview.text))
        #expect(preview.truncated)
        #expect(!preview.text.contains("末尾约束必须保留"))
        #expect(try await store.cueMessages().filter { $0.author == .known(.you) }.isEmpty)
        try db.exec("DROP TRIGGER voice_preview_failure")
        try await fixture.workspace.retryVoiceRequest("original")
        let id = try #require(fixture.call.requests.first?.message)
        let message = try #require(try await store.cueMessages([id]).first)
        #expect(message.text == original)
        let recorded = try #require(try services.voice.macProjection(fixture.call).requests.first)
        #expect(recorded.reference == .recorded(message: id))
        #expect(recorded.preview == nil)
        try await fixture.hangUp()
    }
}
#endif
