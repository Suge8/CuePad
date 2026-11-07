#if os(macOS)
import CuePi
import CueStore
import CueText
import Foundation
import Observation
import os

/// 和 Cue 通话（这台 Mac 上）：实时语音模型（`VoiceWire.model`）只当 Cue 的耳朵和嘴。它听到的请求交出来（交接），这里原样当你对 Cue 说的一句写进对话
/// （`tell`，与"对 Cue 说"同一个入口：`cueMessages` 一条你的消息，Cue 照常回答）；Cue 写进对话的话从库的订阅读到，交回模型念出来。
/// 模型自己的寒暄与转写不落库，对话只有 `cueMessages` 一份；"停下"之类也只是交给 Cue 的一句，由它用自己的停止去做。
/// 凭证每次通话向本机 Codex 要（`AgentIntegration.codexAccess`），不续期、不碰 Codex 的文件。
///
/// 状态只有 `Phase` 一个，所有输入（媒体、控制通道、Cue 的话、挂断）排进同一条队（`inputs`）按序处理：
/// - 连接中 → 媒体连通后开控制通道，收到 `session.started` 进聆听；拿令牌、建通话、媒体、控制通道任一失败进出错。
/// - 聆听 → 模型交出一句（`delegation.created`）写给 Cue，进交接中；模型自己开口（寒暄）进朗读。
/// - 交接中 → Cue 写下回话，交回模型（`delegation.context.append`），进朗读；等的时候模型的过渡语（"我看看"）不改状态。
/// - 朗读 → 模型这一轮说完（`turn.done`）或用户插话（用户的 `turn.created`）回聆听；期间又有交接就进交接中。
/// - 不在等交接时 Cue 又说了话（它自己醒来做完了一件事）：直接交给模型念（`session.context.append`），进朗读。
/// - 任何时候：挂断进结束；媒体断开、控制通道断开、服务器报错进出错（通话随之关掉，不重连）。结束、出错是终态，再通话就新起一个。
@Observable
final class VoiceCall {
    enum Phase: Equatable {
        case connecting, listening, handingOff, speaking, ended
        case failed(Failure)
    }

    enum Failure: Error, Equatable {
        case codex(CodexAccessError)
        case wire(VoiceWire.Failure)
        case media
        case closed(String)
        case server(String)
        case other(String)
    }

    struct Dependencies {
        var access: () async throws -> CodexAccess
        /// 把交出来的那句当你对 Cue 说的写进对话（`Workspace.speak` 到 `.cue`）
        var tell: (String) -> Void
        var store: CueStore
        var cueName: String
        var source: VoicePeer.Source = .microphone
        var recording: URL?
    }

    private(set) var phase: Phase = .connecting
    /// 这次通话到此刻用掉的音频时长（服务器报的，毫秒）
    private(set) var audioMs = 0
    /// 建通话时 Codex 周额度用掉的百分比
    private(set) var usedPercent: Double?
    /// 关键节点的时刻（测量用：建通话、开始聆听、交接、Cue 回话、交回、模型开口、每轮说完的转写……）
    @ObservationIgnored var mark: (String) -> Void = { _ in }

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private let peer: VoicePeer
    @ObservationIgnored private let session = UUID()
    @ObservationIgnored private let started = Date.now
    @ObservationIgnored private let inputs = AsyncStream<Input>.makeStream()
    @ObservationIgnored private var sideband: URLSessionWebSocketTask?
    @ObservationIgnored private var access: CodexAccess?
    @ObservationIgnored private var callID: String?
    /// 还在等 Cue 回话的那次交接
    @ObservationIgnored private var waiting: String?
    @ObservationIgnored private var spoken: Set<UUID> = []
    private nonisolated static let log = Logger(subsystem: AppIdentity.id, category: "voice")

    private enum Input {
        case peer(VoicePeer.Event)
        case wire(Result<VoiceWire.Event, VoiceWire.SidebandClosed>)
        case cue([CueMessage])
        case storeFailed(String)
        case hangUp
    }

    init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
        peer = VoicePeer(source: dependencies.source, recording: dependencies.recording)
        peer.onEvent = { [inputs] in inputs.continuation.yield(.peer($0)) }
    }

    var isLive: Bool { phase != .ended && !phase.isFailure }

    func hangUp() { inputs.continuation.yield(.hangUp) }

    /// 跑完整个通话（到结束或出错）。
    func run() async {
        do {
            try await connect()
        } catch {
            return await finish(.failed(Self.failure(error)))
        }
        let replies = Task { [inputs, store = dependencies.store, started] in
            do {
                for try await messages in store.observe({ try $0.cueMessages(limit: 8).filter { $0.author == .known(.cue) && $0.createdAt >= started } }) {
                    inputs.continuation.yield(.cue(messages))
                }
            } catch {
                inputs.continuation.yield(.storeFailed(error.localizedDescription))
            }
        }
        defer { replies.cancel() }
        for await input in inputs.stream {
            if let end = handle(input) { return await finish(end) }
        }
    }

    private func connect() async throws {
        let access = try await dependencies.access()
        self.access = access
        let offer = try await peer.offer()
        let call = try await VoiceWire.createCall(offer: offer, instructions: Self.instructions(name: dependencies.cueName), access: access, session: session)
        callID = call.id
        usedPercent = call.usedPercent
        mark("call")
        try await peer.accept(answer: call.answer)
    }

    /// 处理一个输入；返回终态时通话到此为止。
    private func handle(_ input: Input) -> Phase? {
        switch input {
        case .hangUp:
            return .ended
        case .peer(.connected):
            mark("media")
            guard let callID, let access else { return nil }
            sideband = VoiceWire.sideband(call: callID, access: access, session: session) { [inputs] in inputs.continuation.yield(.wire($0)) }
        case .peer(.failed):
            return .failed(.media)
        case .peer(.inputEnded):
            mark("input-ended")
        case .peer(.output(let loud)):
            mark(loud ? "output-loud" : "output-quiet")
        case .wire(.failure(let closed)):
            return phase == .connecting ? .failed(.closed("\(closed.status.map(String.init) ?? "-") \(closed.reason)")) : .failed(.closed(closed.reason))
        case .wire(.success(let event)):
            return handle(event)
        case .storeFailed(let reason):
            return .failed(.other(reason))
        case .cue(let messages):
            // 控制通道开之前 Cue 说的留到下一次读到再念
            guard let sideband else { return nil }
            for message in messages where !spoken.contains(message.id) {
                spoken.insert(message.id)
                say(message, on: sideband)
            }
        }
        return nil
    }

    private func handle(_ event: VoiceWire.Event) -> Phase? {
        switch event {
        case .started:
            mark("listening")
            if phase == .connecting {
                phase = .listening
                if case .file = dependencies.source { Task { try? await peer.play() } }
            }
        case .delegation(let id, let text):
            mark("handoff")
            Self.log.info("交接：\(text, privacy: .private)")
            waiting = id
            phase = .handingOff
            dependencies.tell(text)
        case .turn(let assistant, let done, let text):
            if done { mark("\(assistant ? "assistant" : "user")-said \(text)") }
            if assistant, !done, phase == .listening { phase = .speaking }
            if assistant, done, phase == .speaking { phase = .listening }
            if !assistant, !done, phase == .speaking { phase = .listening }
            if assistant, !done { mark("assistant-turn") }
        case .usage(let ms):
            audioMs = ms
        case .error(let message):
            return .failed(.server(message))
        }
        return nil
    }

    /// Cue 写下的一句交给模型念：在等交接就作为这次交接的回话，不然直接念。
    private func say(_ message: CueMessage, on sideband: URLSessionWebSocketTask) {
        let text = CueFormat.hasAttachments(message.text) ? CueFormat.parse(message.text).map(\.shownText).joined() : message.text
        mark("cue-reply")
        if let waiting {
            VoiceWire.send(.reply(delegation: waiting, text: text), on: sideband)
            self.waiting = nil
        } else {
            VoiceWire.send(.say(text), on: sideband)
        }
        phase = .speaking
    }

    private func finish(_ end: Phase) async {
        if let sideband {
            VoiceWire.send(.close, on: sideband)
            sideband.cancel(with: .normalClosure, reason: nil)
        }
        sideband = nil
        await peer.close()
        inputs.continuation.finish()
        phase = end
        mark("end")
    }

    private static func failure(_ error: Error) -> Failure {
        switch error {
        case let error as CodexAccessError: .codex(error)
        case let error as VoiceWire.Failure: .wire(error)
        default: .other(error.localizedDescription)
        }
    }

    /// 给实时模型的话：它是 Cue 的声音，什么都交给后台（Cue），后台的话照意思简短说出来。
    static func instructions(name: String) -> String {
        """
        You are the voice of \(name), the user's assistant. You are only the ears and the mouth: \(name)'s backend does all the thinking and all the work.

        - Delegate every request, question, instruction, correction and "stop" to the backend. You may tidy what the user said: drop filler words and fold mid-sentence corrections into what they finally meant. Keep every condition the user stated, and add no judgement or content of your own. Never answer from your own knowledge, never invent results, never claim something was done.
        - While waiting, say at most one very short acknowledgement, then stay quiet.
        - When the backend replies, tell the user what it said, briefly and naturally, in the user's language. Do not read out lists, tables, code, links or IDs; give the gist. Add nothing of your own: no offers, suggestions or follow-up questions.
        - Backend messages that arrive without a request are updates from \(name): pass them on the same way.
        - Present everything as \(name) speaking. Never mention a backend, delegation or another system.
        """
    }
}

extension VoiceCall.Phase {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}
#endif
