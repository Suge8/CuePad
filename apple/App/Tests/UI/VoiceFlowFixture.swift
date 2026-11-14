#if os(macOS)
import CueBridge
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
    var voiceRecord: VoiceRecord { call.record }

    init(_ services: AppServices) { workspace = Workspace(services: services) }

    /// 请求在库里的那条记录（送达回执都写在它上面）
    func stored(_ id: UUID? = nil) -> CueMessage? {
        guard let message = call.record.requests.first(where: { id == nil || $0.message == id })?.message else { return nil }
        return try? workspace.services.store.snapshot { try $0.cueMessages([message]).first }.value
    }

    /// 通话详情此刻的样子：与 `VoiceHost` 同一份投影与库记录。
    func details() throws -> CueVoicePresentation {
        let state = workspace.voiceViewState, ids = state.recordIDs
        return state.reading(try workspace.services.store.snapshot { try VoiceRecords.read(ids, from: $0) }.value).presentation()
    }

    /// 详情里这个会话那一行的停止动作（Mac 投影给的那一轮）
    func stopAction(_ session: String) async throws -> VoiceAction {
        try await eventually("\(session) 这一行能停") { try self.details().executions.first { $0.id == session }?.stop != nil }
        return try #require(try details().executions.first { $0.id == session }?.stop)
    }

    /// 按那一行的停止钮停下会话，返回停止请求
    func stop(_ session: String) async throws -> DeliveryRequest {
        let outcome = try await workspace.performVoice(try await stopAction(session))
        guard case .stopRequested(let id)? = outcome else { Issue.record("停止被拒：\(String(describing: outcome))"); throw CancellationError() }
        return try #require(try await workspace.services.store.deliveryRequest(id))
    }

    /// 那条没落库的请求在详情里的恢复动作
    func recovery(of delegation: String) -> VoiceAction? {
        voiceRecord.requests.first { $0.id == delegation }.map { .recover(.unrecorded(session: $0.origin, request: $0.rowID)) }
    }

    func trip(_ id: UUID? = nil) -> Speech.Trip? {
        stored(id).map { Said.cue($0, host: workspace.cue.hostID).trip(at: workspace.services.speech) }
    }

    func start() {
        // 通话挂断后仍留在服务里（`VoiceService.call`），连同这些依赖：弱持有替身，不然替身、它的工作区与服务互相攥着放不掉
        workspace.services.voice.makeCall = { [weak self] dependencies, record in
            var dependencies = dependencies
            dependencies.access = { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.access()
            }
            dependencies.media = { [weak self] _ in self?.media ?? Media() }
            dependencies.createCall = { [weak self] _, _, voice, _, _ in
                if let error = self?.connectError { throw error }
                self?.voices.append(voice)
                return VoiceWire.Call(id: "rtc_isolated", answer: "answer", usedPercent: nil)
            }
            dependencies.control = { [weak self] _, _, _, received in
                guard let self else { return Control() }
                self.received = received
                let control = Control()
                self.controls.append(control)
                received(.success(.started))
                return control
            }
            return VoiceCall(dependencies, record: record)
        }
        workspace.startVoiceCall()
    }

    func connect() async throws {
        start()
        try await eventually("通话可听") { self.call.phase == .listening }
    }

    func handoff(_ text: String, id: String = UUID().uuidString) async throws -> UUID {
        received?(.success(.delegation(.init(id: id, turn: nil, text: text))))
        try await eventually("请求落库") { self.call.record.requests.first { $0.id == id }?.message != nil }
        return try #require(call.record.requests.first { $0.id == id }?.message)
    }

    func hangUp() async throws {
        call.hangUp()
        try await eventually("通话已收尾") { !self.call.isLive }
    }
}
#endif
