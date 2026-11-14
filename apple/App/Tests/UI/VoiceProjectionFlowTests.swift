#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
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
        try await eventually("原请求保存失败") { fixture.voiceRecord.requests.first?.failure != nil }
        let projection = try services.voice.fullProjection(fixture.call)
        let request = try #require(projection.requests.first)
        let preview = try #require(request.preview)
        #expect(!preview.text.isEmpty && original.hasPrefix(preview.text))
        #expect(preview.truncated)
        #expect(!preview.text.contains("末尾约束必须保留"))
        #expect(try await store.cueMessages().filter { $0.author == .known(.you) }.isEmpty)
        try db.exec("DROP TRIGGER voice_preview_failure")
        let outcome = try await fixture.workspace.performVoice(try #require(fixture.recovery(of: "original")))
        let id = try #require(fixture.voiceRecord.requests.first?.message)
        #expect(outcome == .recorded(message: id))
        let message = try #require(try await store.cueMessages([id]).first)
        #expect(message.text == original)
        let recorded = try #require(try services.voice.fullProjection(fixture.call).requests.first)
        #expect(recorded.reference == .recorded(message: id))
        #expect(recorded.preview == nil)
        try await fixture.hangUp()
    }

    /// 手机那端被来电收走声音而挂断（手机的媒体在 Mac 这边就是一个带原因结束的媒体）：投影给手机的是同一个原因，手机显示"音频已中断"而不是"声音连接断了"。
    @Test func 媒体那端带原因结束_投影原样给手机() async throws {
        let app = TestApp(), services = app.services!, host = TestApp.hostID
        try await services.store.updateCueProfile { $0.enabledAt = .now; $0.hostID = host }
        let fixture = VoiceFlowFixture(services)
        defer { services.cancelBackgroundWork() }
        try await fixture.connect()
        fixture.media.onEvent(.ended(.audioInterrupted))
        try await eventually("通话按媒体给的原因结束") { !fixture.call.isLive }
        #expect(try services.voice.fullProjection(fixture.call).phase == .failed(.ended(.audioInterrupted)))
    }

    /// 跨版本合同：信令 1 的手机打进来，新 Mac 回的"请更新"投影旧手机得解得开。
    /// 下面是 04b9637f6 的 Mac 拒绝来电时发出的那份（照旧代码的形状抄），旧手机的解码器只认这个形状：它有的键新的都得有、类型相同，阶段原样。
    @Test func 旧手机拨号_回的请更新投影旧手机解得开() async throws {
        let old = #"{"projection":{"value":{"canRepeat":false,"executions":[],"omitted":{"executions":0,"replies":0,"requests":0},"pages":{"executions":{"version":""},"replies":{"version":""},"requests":{"version":""}},"phase":{"failed":{"_0":{"relayUnsupported":{}}}},"replies":[],"requests":[],"response":"none","session":{"rawValue":"00000000-0000-0000-0000-000000000000"}}}}"#
        let app = TestApp(), services = app.services!, host = TestApp.hostID
        defer { services.cancelBackgroundWork() }
        try await services.store.updateCueProfile { $0.enabledAt = .now; $0.hostID = host }
        let signal = OldPhoneSignaling()
        services.voice = VoiceService(services: services, signaling: signal)
        await services.voice.receive(signal.event(.media(signal: .offer(value: .init(sdp: "offer", version: nil))), session: .init(UUID())))
        try await eventually("回了投影") { !signal.sent.isEmpty }
        #expect(services.voice.call == nil, "不为旧手机建通话")
        let sent = try JSONSerialization.jsonObject(with: VoiceSignalFormat.canonicalJSON(try #require(signal.sent.first)))
        let expected = try JSONSerialization.jsonObject(with: Data(old.utf8))
        #expect(Self.readable(expected, by: sent, at: ""), "旧手机解不开新 Mac 的拒绝投影")
    }

    /// old 里的每个键在 new 里都有、JSON 类型相同；阶段要原样相等（旧手机靠它显示"请更新"）
    static func readable(_ old: Any, by new: Any, at path: String) -> Bool {
        if path.hasSuffix(".phase") { return (old as? NSDictionary) == (new as? NSDictionary) }
        switch (old, new) {
        case (let old as [String: Any], let new as [String: Any]):
            return old.allSatisfy { key, value in new[key].map { readable(value, by: $0, at: path + "." + key) } ?? false }
        case (is [Any], is [Any]), (is String, is String): return true
        case (let old as NSNumber, let new as NSNumber): return CFGetTypeID(old) == CFGetTypeID(new)
        default: return false
        }
    }
}

@MainActor private final class OldPhoneSignaling: VoiceSignaling {
    let local = VoiceEndpoint(device: .init("mac"), lease: UUID())
    let phone = VoiceEndpoint(device: .init("old-phone"), lease: UUID())
    var voiceAvailability: VoiceRelayAvailability { .ready(endpoint: local) }
    var voiceEvents: AsyncStream<VoiceRelayEvent> { AsyncStream { _ in } }
    var sent: [VoiceSignalPayload] = []
    func resolveVoicePeer(_ device: VoiceDeviceID) async throws -> VoiceEndpoint { phone }
    func sendVoice(_ payload: VoiceSignalPayload, session: VoiceSessionID, to recipient: VoiceEndpoint) async throws { sent.append(payload) }
    func event(_ payload: VoiceSignalPayload, session: VoiceSessionID) -> VoiceRelayEvent {
        .received(.init(header: .init(version: VoiceSignalFormat.version, sender: phone, recipient: local, session: session, sequence: 1,
                                      expiresAtMilliseconds: Int64(Date.now.timeIntervalSince1970 * 1000) + 30000, purpose: payload.purpose), payload: payload))
    }
}
#endif
