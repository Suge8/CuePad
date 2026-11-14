#if os(macOS)
import CueBridge
import CueStore
import Foundation
import Observation
import OSLog

/// GPT Live 负责听说与筛选，只有 delegation 派活；派出的请求与 Cue 的结果记在 `VoiceRecord`。
/// 一通一个，结束后不复用：挂断后仍跟随库里这一通派出请求的结果，直到下一通开始；下一通从空记录开始，上一通的请求留在聊天里。
/// 已提交或半途失败的结果须明确请求再说。
@Observable
final class VoiceCall {
    static let log = Logger(subsystem: AppIdentity.id, category: "voice")
    enum Phase: Equatable {
        case connecting, listening, speaking, closing, ended
        case failed(Failure)
    }

    enum Failure: Error, Equatable {
        case codex(CodexAccessError)
        case wire(VoiceWire.Failure)
        case microphoneDenied, timedOut
        /// 媒体那端带着原因结束（本机的声音断了、手机那端被来电收走声音、没给麦克风……），原因原样投影给手机
        case media(VoiceEndReason)
        case closed(String), server(String), other(String)
    }

    struct Dependencies {
        var access: () async throws -> CodexAccess
        var source: VoicePeer.Source = .microphone
        var media: (VoicePeer.Source) -> any VoiceMedia = { VoicePeer(source: $0) }
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
    private var inputSamples: [Double] = []
    private var outputSamples: [Double] = []
    /// 50ms 一点，保留最近 1.8 秒；静音不呈现输入，远端出声时呈现输出。
    var samples: [Double] { outputActive ? outputSamples : isMuted ? [] : inputSamples }
    private(set) var userTurn: String?
    let record: VoiceRecord
    private(set) var isMuted = false
    private(set) var audioMs = 0
    private(set) var usedPercent: Double?
    @ObservationIgnored var mark: (String) -> Void = { _ in }
    /// 收尾完成（声音与连接都已停下）时调一次
    @ObservationIgnored var ended: () -> Void = {}
    @ObservationIgnored let dependencies: Dependencies
    @ObservationIgnored private var peer: (any VoiceMedia)?
    @ObservationIgnored private(set) var session = UUID()
    @ObservationIgnored let inputs = AsyncStream<Input>.makeStream()
    @ObservationIgnored private var connecting: Task<Void, Never>?
    @ObservationIgnored private var muting: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var outgoing: (attempt: UUID, message: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var delegations: Set<String> = []
    @ObservationIgnored private var inputPeak = 0.0
    @ObservationIgnored private var started = false
    static let connectionLimit: Duration = .seconds(30)

    enum Input {
        case prepared(VoiceWire.Call, CodexAccess)
        case failed(Failure)
        /// 连接时限到了：处理时已就绪就不算（就绪与到时可能同时排在输入里）
        case deadline
        case peer(VoicePeer.Event)
        case wire(Result<VoiceWire.Event, VoiceWire.SidebandClosed>)
        case sent(UUID, Failure?)
        case muted(Bool)
        case hangUp
    }

    init(_ dependencies: Dependencies, record: VoiceRecord) {
        self.dependencies = dependencies
        self.record = record
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

    /// 只能开始一次；media 给了就用它（手机打进来的那一路），没给按 `Dependencies.source` 建本机的。
    func start(session: UUID = UUID(), media: (any VoiceMedia)? = nil) {
        guard !started else { return }
        started = true
        peer = media
        connection = .connecting
        self.session = session
        Task { await run() }
    }

    func setMuted(_ muted: Bool) {
        guard canMute, let peer else { return }
        muting = Task { [inputs] in
            do { try await peer.setMuted(muted); inputs.continuation.yield(.muted(muted)) }
            catch { if !Task.isCancelled { inputs.continuation.yield(.failed(Self.failure(error))) } }
        }
    }

    /// 输入从起点就有人消费；连接时限包含凭证、权限、建连和控制连接，挂断不等它们返回。
    private func run() async {
        record.call = self
        do { try record.begin() }
        catch { await finish(.failed(Self.failure(error))); return }
        let peer = self.peer ?? dependencies.media(dependencies.source)
        self.peer = peer
        peer.onEvent = { [inputs] in inputs.continuation.yield(.peer($0)) }
        deadline = Task { [inputs] in
            do { try await Task.sleep(for: Self.connectionLimit); inputs.continuation.yield(.deadline) }
            catch { }
        }
        connecting = Task { [inputs, dependencies, session, store = record.store] in
            do {
                let access = try await dependencies.access()
                try Task.checkCancellation()
                let offer = try await peer.offer()
                try Task.checkCancellation()
                let cue = try await store.cueProfile() ?? CueProfile()
                try Task.checkCancellation()
                let call = try await dependencies.createCall(offer, Self.identity(name: cue.name), cue.callVoice, access, session)
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
        case .hangUp: return .ended
        case .failed(let failure): return .failed(failure)
        case .deadline: if case .ready = connection { break } else { return .failed(.timedOut) }
        case .prepared(let call, let access):
            usedPercent = call.usedPercent
            connection = .media(call, access)
            mark("call")
        case .peer(.connected):
            if case .media(let call, let access) = connection {
                mark("media")
                connection = .starting(dependencies.control(call.id, access, session) { [inputs] in inputs.continuation.yield(.wire($0)) })
            }
        case .peer(.ended(let reason)): return reason == .hungUp ? .ended : .failed(.media(reason))
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
            record.submitted(sent.message)
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
            }
        case .delegation(let delegation):
            if record.submit(delegation, origin: VoiceSessionID(session)) {
                delegations.insert(delegation.id)
                mark("handoff \(delegation.id)")
            }
        case .turn(let id, let assistant, let done, let text):
            if done { mark("\(assistant ? "assistant" : "user")-said \(id) \(text)") }
            else if assistant { mark("assistant-turn \(id)") }
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
        // 界面只说归类后的原因（`VoiceService.issue(for:)`），上游原文只进日志
        if case .failed(let failure) = end { Self.log.error("voice call failed: \(String(describing: failure), privacy: .public)") }
        let previous = connection
        connection = .closing(end)
        inputs.continuation.finish()
        connecting?.cancel()
        muting?.cancel()
        deadline?.cancel()
        outgoing?.task.cancel()
        record.interrupted()
        switch previous {
        case .starting(let channel), .ready(let channel): channel.close()
        default: break
        }
        await peer?.close()
        connection = .finished(end)
        peer = nil
        connecting = nil
        muting = nil
        deadline = nil
        outgoing = nil
        outputActive = false
        if case .microphone = dependencies.source { mark(String(format: "input-max %.3f", inputPeak)) }
        mark("end")
        ended()
    }

    /// 库读不了：还通着就以这个原因结束。
    func fail(_ failure: Failure) {
        if isLive { inputs.continuation.yield(.failed(failure)) }
    }

    /// 这条结果的来源后来认出不是这几通派的：正在提交的那次作废。
    func withdraw(_ message: UUID) {
        guard outgoing?.message == message else { return }
        outgoing?.task.cancel()
        outgoing = nil
    }

    /// 明确重说：只认这一通（mediaSession）还连着时，规则同自动朗读（`VoiceRecord.requeue`）。
    func repeatReply(_ id: UUID, mediaSession: VoiceSessionID) throws -> VoiceCommandResult.Outcome {
        guard VoiceSessionID(session) == mediaSession, canRepeat else { return .rejected(reason: .originalMissing) }
        let outcome = try record.requeue(id)
        drain()
        return outcome
    }

    /// 可见结果与传输分开推进。send 结束只记本机提交；异步服务端错误仍会使已提交结果变为未确认。
    func drain() {
        guard let channel, outgoing == nil, let next = record.takeQueued(delegations: delegations) else { return }
        let outgoingMessage: VoiceWire.Outgoing = next.delegation.map { .reply(delegation: $0, text: next.text) } ?? .say(next.text)
        let attempt = UUID()
        let task = Task { [inputs, mark] in
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(Speech.sendLimit)); inputs.continuation.yield(.sent(attempt, .timedOut)) }
                catch { }
            }
            defer { timeout.cancel() }
            do {
                mark("cue-forward \(next.message) delegation=\(next.delegation ?? "session") \(next.text)")
                try await channel.send(outgoingMessage)
                try Task.checkCancellation()
                inputs.continuation.yield(.sent(attempt, nil))
            } catch {
                if !Task.isCancelled { inputs.continuation.yield(.sent(attempt, .closed(error.localizedDescription))) }
            }
        }
        outgoing = (attempt, next.message, task)
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
