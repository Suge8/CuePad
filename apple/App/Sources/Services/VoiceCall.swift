#if os(macOS)
import CuePi
import CueStore
import Foundation
import Observation

/// GPT Live 筛选、整理并交接需要 Cue 处理的请求；转写只供通话观察，不写入 Cue。
/// 已交接身份保留到挂断，Cue 的 answeredRequests 决定结果归属；模型音轨的实际电平决定说话状态。
/// 上下文送达不代表模型必然播报，也不保证模型不会在结果返回前自行确认。
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
        var tell: (String) async throws -> UUID
        var store: CueStore
        var cueName: String
        var source: VoicePeer.Source = .microphone(device: nil)
        var recording: URL?
    }

    enum Connection {
        case connecting
        case media(VoiceWire.Call, CodexAccess)
        case starting(VoiceWire.Channel)
        case ready(VoiceWire.Channel)
        case finished(Phase)
    }

    struct Request {
        enum Submission { case recording, recorded(UUID), returned(UUID) }
        let delegation: VoiceWire.Delegation
        var submission: Submission = .recording
        var message: UUID? {
            switch submission {
            case .recording: nil
            case .recorded(let id), .returned(let id): id
            }
        }
        var pending: Bool { if case .returned = submission { false } else { true } }
    }

    private var connection: Connection = .connecting
    private var outputActive = false
    private(set) var userTurn: String?
    var requests: [Request] = []
    private(set) var audioMs = 0
    private(set) var usedPercent: Double?
    @ObservationIgnored var mark: (String) -> Void = { _ in }
    @ObservationIgnored let dependencies: Dependencies
    @ObservationIgnored private let peer: VoicePeer
    @ObservationIgnored private let session = UUID()
    @ObservationIgnored let inputs = AsyncStream<Input>.makeStream()
    @ObservationIgnored private var connecting: Task<Void, Never>?
    @ObservationIgnored private var observing: Task<Void, Never>?
    @ObservationIgnored private var fileInput: Task<Void, Never>?
    @ObservationIgnored var writing: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var outgoing: Task<Void, Never>?
    @ObservationIgnored var cursor = 0
    @ObservationIgnored var latest = 0
    @ObservationIgnored var pending: [CueMessagePage.Entry] = []
    @ObservationIgnored private var inputPeak = 0.0

    enum Input {
        case prepared(VoiceWire.Call, CodexAccess)
        case failed(Failure)
        case peer(VoicePeer.Event)
        case wire(Result<VoiceWire.Event, VoiceWire.SidebandClosed>)
        case changed(Int)
        case loaded(CueMessagePage)
        case recorded(delegation: String, message: UUID)
        case sent(sequence: Int, requests: Set<UUID>, forwarded: UUID?)
        case hangUp
    }

    init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
        peer = VoicePeer(source: dependencies.source, recording: dependencies.recording)
        peer.onEvent = { [inputs] in inputs.continuation.yield(.peer($0)) }
    }

    var phase: Phase {
        switch connection {
        case .connecting, .media, .starting: return .connecting
        case .finished(let end): return end
        case .ready: break
        }
        if outputActive { return .speaking }
        return requests.contains(where: \.pending) ? .handingOff : .listening
    }

    var channel: VoiceWire.Channel? {
        if case .ready(let channel) = connection { channel } else { nil }
    }
    var isLive: Bool { if case .finished = connection { false } else { true } }
    func hangUp() { inputs.continuation.yield(.hangUp) }

    /// 输入从起点就有人消费，挂断不等凭证、权限或网络返回。
    func run() async {
        do {
            let start = try dependencies.store.snapshot { try $0.lastWrite() }
            cursor = start.value
            latest = cursor
            observing = Task { [inputs, store = dependencies.store] in
                do {
                    for try await end in store.observe(from: start, { try $0.lastWrite() }) { inputs.continuation.yield(.changed(end)) }
                } catch { inputs.continuation.yield(.failed(.other(error.localizedDescription))) }
            }
            connecting = Task { [self] in
                do { try await connect() }
                catch { if !Task.isCancelled { inputs.continuation.yield(.failed(Self.failure(error))) } }
            }
            for await input in inputs.stream {
                if let end = handle(input) { await finish(end); return }
                drain()
            }
        } catch { await finish(.failed(Self.failure(error))) }
    }

    private func connect() async throws {
        try Task.checkCancellation()
        let access = try await dependencies.access()
        try Task.checkCancellation()
        let offer = try await peer.offer()
        try Task.checkCancellation()
        let call = try await VoiceWire.createCall(offer: offer, instructions: Self.instructions(name: dependencies.cueName), access: access, session: session)
        try Task.checkCancellation()
        inputs.continuation.yield(.prepared(call, access))
        try await peer.accept(answer: call.answer)
        try Task.checkCancellation()
    }

    private func handle(_ input: Input) -> Phase? {
        switch input {
        case .hangUp: return .ended
        case .failed(let failure): return .failed(failure)
        case .prepared(let call, let access):
            usedPercent = call.usedPercent
            connection = .media(call, access)
            mark("call")
        case .peer(.connected):
            if case .media(let call, let access) = connection {
                mark("media")
                connection = .starting(VoiceWire.Channel(call: call.id, access: access, session: session) { [inputs] in inputs.continuation.yield(.wire($0)) })
            }
        case .peer(.failed): return .failed(.media)
        case .peer(.inputEnded): mark("input-ended")
        case .peer(.device(let label)): mark("device \(label)")
        case .peer(.level(let side, let loud, let peak)):
            if side == .input { inputPeak = max(inputPeak, peak) }
            else { outputActive = loud }
            mark(loud ? "\(side.rawValue)-loud" : String(format: "%@-quiet peak=%.3f", side.rawValue, peak))
        case .wire(.failure(let closed)): return .failed(.closed(closed.reason))
        case .wire(.success(let event)): return handle(event)
        case .changed(let end): latest = max(latest, end)
        case .loaded(let page):
            outgoing = nil
            pending = page.entries
            if pending.isEmpty { cursor = max(cursor, page.through) }
        case .recorded(let delegation, let message):
            writing[delegation] = nil
            if let index = requests.firstIndex(where: { $0.delegation.id == delegation }) { requests[index].submission = .recorded(message) }
        case .sent(let sequence, let answered, let forwarded):
            outgoing = nil
            pending.removeFirst()
            cursor = sequence
            for index in requests.indices {
                if let id = requests[index].message, answered.contains(id) { requests[index].submission = .returned(id) }
            }
            if let forwarded { mark("cue-sent \(forwarded)") }
        }
        return nil
    }

    private func handle(_ event: VoiceWire.Event) -> Phase? {
        switch event {
        case .started:
            if case .starting(let channel) = connection {
                connection = .ready(channel)
                mark("listening")
                if case .file = dependencies.source {
                    fileInput = Task { [peer, inputs] in
                        do { try await peer.play() }
                        catch { if !Task.isCancelled { inputs.continuation.yield(.failed(.media)) } }
                    }
                }
            }
        case .delegation(let delegation): submit(delegation)
        case .turn(let id, let assistant, let done, let text):
            if done { mark("\(assistant ? "assistant" : "user")-said \(id) \(text)") }
            else if assistant { mark("assistant-turn \(id)") }
            if !assistant {
                if !done { userTurn = id }
                else if userTurn == id { userTurn = nil }
            }
        case .context(let delegation, let endMs):
            mark("context-accepted \(delegation ?? "session") end=\(endMs)")
        case .usage(let ms): audioMs = ms
        case .error(let message): return .failed(.server(message))
        }
        return nil
    }

    private func finish(_ end: Phase) async {
        let previous = connection
        inputs.continuation.finish()
        connecting?.cancel()
        observing?.cancel()
        fileInput?.cancel()
        outgoing?.cancel()
        writing.values.forEach { $0.cancel() }
        switch previous {
        case .starting(let channel), .ready(let channel): channel.close()
        default: break
        }
        do { try await peer.close(); connection = .finished(end) }
        catch { connection = .finished(.failed(Self.failure(error))) }
        connecting = nil
        observing = nil
        fileInput = nil
        outgoing = nil
        writing.removeAll()
        if case .microphone = dependencies.source { mark(String(format: "input-max %.3f", inputPeak)) }
        mark("end")
    }

    private static func failure(_ error: Error) -> Failure {
        switch error {
        case let error as CodexAccessError: .codex(error)
        case let error as VoiceWire.Failure: .wire(error)
        default: .other(error.localizedDescription)
        }
    }

    static func instructions(name: String) -> String {
        """
        You are the voice of \(name), the user's assistant. Speak naturally in the user's language. You can chat and clarify; \(name)'s backend handles requests about the user's cards, tasks, projects and ongoing work.

        - Delegate work, questions about the user's data, and changes to previous requests. This includes updating or cancelling work. Organize the relevant context into one concise, self-contained request; preserve the user's titles, dates and constraints exactly. Delegate each request once.
        - Handle greetings and ordinary conversation yourself. Do not delegate background speech or private thinking unless the user asks you to act on it. Clarify only when needed to understand what to do.
        - A delegation asks the backend to work; it is not a result. Do not claim an action is complete, changed or stopped before the backend confirms it. While waiting, do not invent an answer.
        - Backend context on the speakable channel is a result to tell the user now, briefly and naturally. Preserve what actually happened and any blocker. Add no invented details, offers or follow-up questions. Do not read code, URLs, IDs or markup aloud.
        - Context may arrive for a delegated request or as a standalone update. Treat backend results as authoritative, while respecting the user's latest instruction and interruptions.
        - Present everything as \(name) speaking. Never mention a backend, delegation or another system.
        """
    }
}

extension VoiceCall.Phase {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}
#endif
