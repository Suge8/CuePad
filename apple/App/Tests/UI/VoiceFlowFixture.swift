#if os(macOS)
import CuePi
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 只替换语音服务与设备边界；开始、派活、读库、恢复与投送都走窗口实际使用的 Workspace。
@MainActor
final class VoiceFlowFixture {
    final class Media: VoiceMedia {
        var onEvent: (VoicePeer.Event) -> Void = { _ in }
        var denied = false
        var muted = false
        var closed = false
        var closeGate: AsyncStream<Void>?
        var closing = false
        func offer() async throws -> String {
            if denied { throw VoicePeerError.microphoneDenied }
            return "offer"
        }
        func accept(answer: String) async throws { onEvent(.connected) }
        func setMuted(_ value: Bool) async throws { muted = value }
        func close() async {
            closing = true
            if let closeGate { for await _ in closeGate {} }
            closed = true
        }
    }

    final class Control: VoiceControl {
        var sends: [VoiceWire.Outgoing] = []
        var failedAfterFirstFragment = false
        var fragments: [[String: Any]] = []
        func send(_ outgoing: VoiceWire.Outgoing) async throws {
            sends.append(outgoing)
            if failedAfterFirstFragment {
                fragments += outgoing.messages.prefix(1)
                throw URLError(.networkConnectionLost)
            }
            fragments += outgoing.messages
        }
        func close() {}
    }

    let workspace: Workspace
    let media = Media()
    var controls: [Control] = []
    var received: ((Result<VoiceWire.Event, VoiceWire.SidebandClosed>) -> Void)?
    var connectError: VoiceWire.Failure?
    /// 每一通建通话时交给服务端的音色
    var voices: [CueVoice] = []
    var access: () async throws -> CodexAccess = {
        let payload = Data(#"{"exp":4102444800,"https://api.openai.com/auth":{"chatgpt_account_id":"isolated-test"}}"#.utf8).base64EncodedString()
        return try #require(CodexAccess(token: "test.\(payload).test"))
    }
    var call: VoiceCall { workspace.voice! }

    init(_ services: AppServices) { workspace = Workspace(services: services) }

    func trip(_ id: UUID? = nil) -> Speech.Trip? {
        call.requests.first { id == nil || $0.message == id }?.record.map {
            Said.cue($0, host: workspace.cue.hostID).trip(at: workspace.services.speech)
        }
    }

    func start() {
        workspace.startVoiceCall { dependencies in
            var dependencies = dependencies
            dependencies.access = { try await self.access() }
            dependencies.media = { _ in self.media }
            dependencies.createCall = { _, _, voice, _, _ in
                if let error = self.connectError { throw error }
                self.voices.append(voice)
                return VoiceWire.Call(id: "rtc_isolated", answer: "answer", usedPercent: nil)
            }
            dependencies.control = { _, _, _, received in
                self.received = received
                let control = Control()
                self.controls.append(control)
                received(.success(.started))
                return control
            }
            return VoiceCall(dependencies)
        }
    }

    func connect() async throws {
        start()
        try await eventually("通话可听") { self.call.phase == .listening }
    }

    func handoff(_ text: String, id: String = UUID().uuidString) async throws -> UUID {
        received?(.success(.delegation(.init(id: id, turn: nil, text: text))))
        try await eventually("请求落库") { self.call.requests.first { $0.id == id }?.record != nil }
        return try #require(call.requests.first { $0.id == id }?.message)
    }

    func hangUp() async throws {
        call.hangUp()
        try await eventually("通话已收尾") { !self.call.isLive }
    }
}
#endif
