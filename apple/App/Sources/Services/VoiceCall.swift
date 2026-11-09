#if os(macOS)
import CuePi
import CueStore
import Foundation
import Observation

/// GPT Live 负责听说与筛选，只有 delegation 派活。库记录是请求、回复与实际执行的依据，转写和音轨都不是业务确认。
/// 通话结束仍跟随库里的结果；重连复用这份记录，只发送从未提交的新结果。已提交或半途失败的结果须明确请求再说。
@Observable
final class VoiceCall {
    enum Phase: Equatable {
        case connecting, listening, handingOff, speaking, closing, ended
        case failed(Failure)
    }

    enum Failure: Error, Equatable {
        case codex(CodexAccessError)
        case wire(VoiceWire.Failure)
        case microphoneDenied, media, timedOut
        case closed(String), server(String), other(String)
    }

    struct Dependencies {
        var access: () async throws -> CodexAccess
        var tell: (String) async throws -> UUID
        var store: CueStore
        var cueName: String
        var source: VoicePeer.Source = .microphone(device: nil)
        var recording: URL?
        var media: (VoicePeer.Source, URL?) -> any VoiceMedia = { VoicePeer(source: $0, recording: $1) }
        var createCall = VoiceWire.createCall
        var control: (String, CodexAccess, UUID, @escaping (Result<VoiceWire.Event, VoiceWire.SidebandClosed>) -> Void) -> any VoiceControl = {
            VoiceWire.Channel(call: $0, access: $1, session: $2, received: $3)
        }
    }

    enum Connection {
        case connecting
        case media(VoiceWire.Call, CodexAccess)
        case starting(any VoiceControl)
        case ready(any VoiceControl)
        case closing(Phase), finished(Phase)
    }

    private var connection: Connection = .finished(.ended)
    private var outputActive = false
    private(set) var waitingForResponse = false
    private(set) var assistantTurns: Set<String> = []
    private(set) var mediaEndReason: VoiceEndReason?
    private var inputSamples: [Double] = []
    private var outputSamples: [Double] = []
    /// 50ms 一点，保留最近 1.8 秒；静音不呈现输入，远端出声时呈现输出。
    var samples: [Double] { outputActive ? outputSamples : isMuted ? [] : inputSamples }
    private(set) var userTurn: String?
    var requestState: [Request] = []
    var replyState: [Reply] = []
    var executionState: [PiSessionListItem] = []
    /// 控制记录会被库定期清理；通话保留最后观察到的真实事实，不由它授予停止权限。
    var stopRequests: [DeliveryRequest] = []
    var executions: [PiSessionListItem] { executionState }
    var requests: [Request] { requestState }
    var replies: [Reply] { replyState }
    private(set) var heard = ""
    private(set) var said = ""
    private(set) var isMuted = false
    private(set) var audioMs = 0
    private(set) var usedPercent: Double?
    var storeFailure: String?
    @ObservationIgnored var mark: (String) -> Void = { _ in }
    @ObservationIgnored var dependencies: Dependencies
    @ObservationIgnored private var peer: (any VoiceMedia)?
    @ObservationIgnored private(set) var session = UUID()
    @ObservationIgnored var inputs = AsyncStream<Input>.makeStream()
    @ObservationIgnored private var connecting: Task<Void, Never>?
    @ObservationIgnored var observing: Task<Void, Never>?
    @ObservationIgnored var reading: Task<Void, Never>?
    @ObservationIgnored private var fileInput: Task<Void, Never>?
    @ObservationIgnored private var muting: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored var writing: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var outgoing: (attempt: UUID, message: UUID, task: Task<Void, Never>)?
    @ObservationIgnored var cursor: Int?
    @ObservationIgnored var latest = 0
    @ObservationIgnored var delegations: Set<String> = []
    @ObservationIgnored private var inputPeak = 0.0
    static let connectionLimit: Duration = .seconds(30)

    enum Input {
        case prepared(VoiceWire.Call, CodexAccess)
        case failed(Failure)
        case peer(VoicePeer.Event)
        case wire(Result<VoiceWire.Event, VoiceWire.SidebandClosed>)
        case sent(UUID, Failure?)
        case muted(Bool)
        case hangUp
    }

    init(_ dependencies: Dependencies) { self.dependencies = dependencies }

    isolated deinit {
        observing?.cancel()
        reading?.cancel()
    }

    var phase: Phase {
        switch connection {
        case .connecting, .media, .starting: return .connecting
        case .closing: return .closing
        case .finished(let end): return end
        case .ready: break
        }
        // 助手回合是协议事实，不是播放游标；电平只驱动本机波形，句间静音不能结束回合。
        // 等待回应与写库另行投影，仍可收音时不把它们冒充媒体 processing。
        return assistantTurns.isEmpty ? .listening : .speaking
    }

    var channel: (any VoiceControl)? {
        if case .ready(let channel) = connection { channel } else { nil }
    }
    var isLive: Bool { if case .finished = connection { false } else { true } }
    var canMute: Bool { channel != nil && muting == nil && peer?.supportsMute == true }
    var canRepeat: Bool { channel != nil }
    func hangUp() { inputs.continuation.yield(.hangUp) }

    /// 重新接通只重建媒体与控制连接；库订阅、请求身份和结果保留，不重新执行业务。
    func reconnect(session: UUID = UUID(), media: (any VoiceMedia)? = nil) {
        guard !isLive else { return }
        peer = media
        inputs = AsyncStream<Input>.makeStream()
        connection = .connecting
        self.session = session
        mediaEndReason = nil
        assistantTurns.removeAll()
        waitingForResponse = false
        delegations.removeAll()
        audioMs = 0
        usedPercent = nil
        isMuted = false
        inputPeak = 0
        inputSamples = []
        outputSamples = []
        userTurn = nil
        Task { await run() }
    }

    func setMuted(_ muted: Bool) {
        guard canMute, let peer else { return }
        muting = Task { [inputs] in
            do { try await peer.setMuted(muted); inputs.continuation.yield(.muted(muted)) }
            catch { if !Task.isCancelled { inputs.continuation.yield(.failed(Self.failure(error))) } }
        }
    }

    /// 输入从起点就有人消费；连接时限包含凭证、权限、ICE 和控制连接，挂断不等它们返回。
    private func run() async {
        guard connecting == nil else { return }
        if cursor == nil {
            do { cursor = try dependencies.store.snapshot { try $0.lastWrite() }.value }
            catch { await finish(.failed(Self.failure(error))); return }
        }
        watchRequests()
        let peer = self.peer ?? dependencies.media(dependencies.source, dependencies.recording)
        self.peer = peer
        peer.onEvent = { [inputs] in inputs.continuation.yield(.peer($0)) }
        deadline = Task { [inputs] in
            do { try await Task.sleep(for: Self.connectionLimit); inputs.continuation.yield(.failed(.timedOut)) }
            catch { }
        }
        connecting = Task { [inputs, dependencies, session] in
            do {
                let access = try await dependencies.access()
                try Task.checkCancellation()
                let offer = try await peer.offer()
                try Task.checkCancellation()
                let call = try await dependencies.createCall(offer, Self.instructions(name: dependencies.cueName), Self.identity(name: dependencies.cueName), access, session)
                try Task.checkCancellation()
                inputs.continuation.yield(.prepared(call, access))
                try await peer.accept(answer: call.answer)
            } catch { if !Task.isCancelled { inputs.continuation.yield(.failed(Self.failure(error))) } }
        }
        for await input in inputs.stream {
            if let end = handle(input) { await finish(end); return }
            drain()
        }
    }

    private func handle(_ input: Input) -> Phase? {
        switch input {
        case .hangUp: mediaEndReason = .hungUp; return .ended
        case .failed(let failure): return .failed(failure)
        case .prepared(let call, let access):
            usedPercent = call.usedPercent
            connection = .media(call, access)
            mark("call")
        case .peer(.connected):
            if case .media(let call, let access) = connection {
                mark("media")
                connection = .starting(dependencies.control(call.id, access, session) { [inputs] in inputs.continuation.yield(.wire($0)) })
            }
        case .peer(.failed): mediaEndReason = .mediaFailed; return .failed(.media)
        case .peer(.ended(let reason)):
            mediaEndReason = reason
            return [.hungUp, .background].contains(reason) ? .ended : .failed(.media)
        case .peer(.inputEnded): mark("input-ended")
        case .peer(.device(let label)): mark("device \(label)")
        case .peer(.sample(let side, let peak)):
            let value = min(1, max(0, peak))
            if side == .input { inputSamples = Array((inputSamples + [value]).suffix(VoicePeer.sampleCount)) }
            else { outputSamples = Array((outputSamples + [value]).suffix(VoicePeer.sampleCount)) }
        case .peer(.level(let side, let loud, let peak)):
            if side == .input { inputPeak = max(inputPeak, peak) }
            else { outputActive = loud }
            mark(loud ? "\(side.rawValue)-loud" : String(format: "%@-quiet peak=%.3f", side.rawValue, peak))
        case .wire(.failure(let closed)): return .failed(.closed(closed.reason))
        case .wire(.success(let event)): return handle(event)
        case .sent(let attempt, let failure):
            guard let sent = outgoing, sent.attempt == attempt else { break }
            if let failure { return .failed(failure) }
            outgoing = nil
            if let index = replies.firstIndex(where: { $0.id == sent.message }) { replyState[index].delivery = .submitted }
            mark("cue-sent \(sent.message)")
        case .muted(let muted): isMuted = muted; muting = nil
        }
        return nil
    }

    private func handle(_ event: VoiceWire.Event) -> Phase? {
        switch event {
        case .started:
            if case .starting(let channel) = connection {
                connection = .ready(channel)
                deadline?.cancel(); deadline = nil
                mark("listening")
                if case .file = dependencies.source, let peer {
                    fileInput = Task { [inputs] in
                        do { try await peer.play() }
                        catch { if !Task.isCancelled { inputs.continuation.yield(.failed(.media)) } }
                    }
                }
            }
        case .delegation(let delegation): submit(delegation)
        case .turn(let id, let assistant, let done, let text):
            if done {
                if assistant { said = text } else { heard = text }
                mark("\(assistant ? "assistant" : "user")-said \(id) \(text)")
            } else if assistant { mark("assistant-turn \(id)") }
            if assistant {
                if done { assistantTurns.remove(id) } else { assistantTurns.insert(id) }
                waitingForResponse = false
            } else {
                waitingForResponse = done
                if !done { userTurn = id }
                else if userTurn == id { userTurn = nil }
            }
        case .context(let delegation, let endMs): mark("context-accepted \(delegation ?? "session") end=\(endMs)")
        case .usage(let ms): audioMs = ms
        case .error(let message): return .failed(.server(message))
        }
        return nil
    }

    private func finish(_ end: Phase) async {
        let previous = connection
        connection = .closing(end)
        inputs.continuation.finish()
        connecting?.cancel()
        fileInput?.cancel()
        muting?.cancel()
        deadline?.cancel()
        outgoing?.task.cancel()
        // 已提交本就不保证播放成功，正常挂断不制造异常；半途取消的发送才需明确请求重说。
        for index in replyState.indices {
            switch replyState[index].delivery {
            case .sending: replyState[index].delivery = .unconfirmed(String(localized: "朗读尚未确认"))
            default: break
            }
        }
        switch previous {
        case .starting(let channel), .ready(let channel): channel.close()
        default: break
        }
        do { try await peer?.close(); connection = .finished(end) }
        catch { connection = .finished(.failed(Self.failure(error))) }
        peer = nil
        connecting = nil
        fileInput = nil
        muting = nil
        deadline = nil
        outgoing = nil
        outputActive = false
        if case .microphone = dependencies.source { mark(String(format: "input-max %.3f", inputPeak)) }
        mark("end")
    }

    private static func failure(_ error: Error) -> Failure {
        switch error {
        case let error as CodexAccessError: .codex(error)
        case let error as VoiceWire.Failure: .wire(error)
        case VoicePeerError.microphoneDenied: .microphoneDenied
        default: .other(error.localizedDescription)
        }
    }
}

extension VoiceCall.Phase {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}
#endif
