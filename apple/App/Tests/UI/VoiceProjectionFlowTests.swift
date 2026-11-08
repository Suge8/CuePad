#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

@MainActor struct VoiceProjectionFlowTests {
    @Test func 未保存原话可辨认_截断不改恢复正文_历史快照不越界() async throws {
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
        let outcome = try await services.voice.command(.recover(request: request.reference))
        guard case .recorded(let id) = outcome else { Issue.record("恢复没有返回原请求的落库身份"); return }
        let message = try #require(try await store.cueMessages([id]).first)
        #expect(message.text == original)
        let recorded = try #require(try services.voice.macProjection(fixture.call).requests.first)
        #expect(recorded.reference == .recorded(message: id))
        #expect(recorded.preview == nil)
        try db.exec("CREATE TRIGGER voice_preview_failure BEFORE INSERT ON cueMessages WHEN NEW.author = 'you' BEGIN SELECT RAISE(FAIL, 'preview flow write failure'); END")
        let count = 100
        for index in 0..<count {
            fixture.received?(.success(.delegation(.init(id: "failed-\(index)", turn: nil, text: "第\(index)条：" + original))))
        }
        try await eventually("所有未保存请求都有各自失败结果") { fixture.call.requests.filter { $0.failure != nil }.count == count }
        let bounded = try services.voice.macProjection(fixture.call)
        let bytes = try VoiceSignalFormat.canonicalJSON(VoiceSignalPayload.projection(value: bounded))
        #expect(bytes.count <= 32 * 1024)
        #expect(bounded.omitted.requests > 0)
        #expect(bounded.requests.count + bounded.omitted.requests == count + 1)
        #expect(bounded.requests.contains { $0.preview?.text.hasPrefix("第99条：") == true })
        #expect(fixture.call.requests.last?.text == "第99条：" + original)
        try db.exec("DROP TRIGGER voice_preview_failure")
        try await fixture.hangUp()
    }
}
#endif
