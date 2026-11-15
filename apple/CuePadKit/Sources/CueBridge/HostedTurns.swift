#if os(macOS)
import CueStore
import Foundation

/// CuePad 托管的会话（与同一套代码开的大脑）的一轮，唯一的一处：各家只把协议翻成 `TurnEvent` 交给 `apply`，一轮的开始、做什么、
/// 结束与出错只在这里改进 `facts`。
/// - 在跑时说一句是换轮（`send`）：先停下这一轮（各家的 `stop` 只发出停止，收尾由这里等，至多 `AgentTimeouts.stop`），被停下的那一轮
///   收尾不报歇下，紧接着由这句开的一轮接上；停不下、被取消或交不出时才歇下。所以每句话只开一轮，两轮之间不会多一次"做完了"的提示。
/// - 一句话的换轮到它交出为止；交出时上一轮已收尾、这句的开始还没到（OpenCode、Codex 的开始从事件流晚到），就到下一次开始为止。
/// - 停下（`abort`）结束所有换轮、取消还在停上一轮的，自己那一段不可取消；被要求停下的这一轮收尾不算出错（`stopping`，到下一轮开始为止）。
@MainActor
final class HostedTurns {
    enum Phase {
        case idle
        case running
        /// 被换轮停下的那一轮已收尾、这句开的一轮还没开始：桥上照旧在跑
        case handedOver
    }

    var facts = SessionFacts()
    private(set) var phase: Phase = .idle
    /// 这一轮被要求停下：它的收尾不算出错
    private(set) var stopping = false
    /// 这一轮发出、没被拒的停止请求有几个：都被拒了才不算被要求停下
    private var stopRequests = 0
    private enum Handover { case halting, delivering, awaitingStart }
    /// 换轮中的话：期间收尾的一轮不歇下。开始说不出是哪句开的，只认领已交出、等开始的（几句可能并进同一轮，一次全认领）；
    /// 交出中的到交出那一刻才看：在跑就是并进了或已开了
    private var handovers: [(token: UUID, step: Handover)] = []
    private var failure: String?
    private var tools: Set<String> = []
    /// 一轮收尾或连接关了
    private let ends: Occurrences
    private let stopPhase = StopPhase()
    /// 不经 `apply` 改了事实时通知主人发布：换轮没开成改为歇下、交出的话成了开轮者（开始可能早于交出返回就报过了）
    var onChange: () -> Void = {}

    init(timing: Timing = .system) {
        ends = Occurrences(timeout: AgentTimeouts.stop, timing: timing, timeoutError: BridgeError.ackTimeout)
    }

    /// Agent 此刻在跑一轮（桥上的 `facts.running` 在换轮的间隙也为真）
    var running: Bool { phase == .running }

    var handingOver: Bool { !handovers.isEmpty }

    /// 返回这件事算不算数（大脑与桥要不要听到它）：已在跑时的开始、没在跑时的工具、出错与结束都不算。
    /// `time` 只对开始有用：要早于这一轮在会话记录里可能的收尾（`SessionFacts.startTurn`）。
    @discardableResult
    func apply(_ event: TurnEvent, at time: Date = .now) -> Bool {
        switch event {
        case .turnStarted:
            guard phase != .running else { return false }
            phase = .running
            (stopping, stopRequests) = (false, 0)
            failure = nil
            tools = []
            handovers.removeAll { $0.step == .awaitingStart }
            facts.startTurn(at: time)
        case .tool(let id, let name, let arguments):
            guard phase == .running else { return false }
            tools.insert(id)
            facts.work(.tool, detail: ToolDetail.line(name, JSONValue.parse(Data(arguments.utf8))))
        case .toolDone(let id, _, _):
            guard phase == .running else { return false }
            tools.remove(id)
            if tools.isEmpty { facts.work(.thinking) }
        case .failed(let text):
            guard phase == .running else { return false }
            failure = text
        case .turnFinished:
            guard phase == .running else { return false }
            finish()
        case .speaking, .context, .received, .exited:
            break
        }
        return true
    }

    private func finish() {
        let failure = stopping ? nil : failure
        (stopping, stopRequests, self.failure, tools) = (false, 0, nil, [])
        if handingOver {
            phase = .handedOver
            facts.questions = []
            facts.work(.thinking)
        } else {
            phase = .idle
            facts.endTurn(failure: failure)
        }
        ends.happened()
    }

    /// 以一句话开新一轮：在跑就先停下（`stop` 发出停止），再 `deliver` 交出这句，它返回就算已交出；各家在交出时（或随后的事件）报这一轮开始。
    /// 开始交出前 `opener` 就成了开轮者（并进在跑的那一轮也是：这一轮从此算它的）：开始与停下可能早于交出返回就报来（Codex 的
    /// `turn/start`），得已经带着它。没交出、或交出后明确被拒收（`BridgeError.refused`，托管的 Claude Code）就换回原来的。
    /// 停上一轮那一段可被 `abort` 取消；交出之后不取消：话已交出，取消会把收下的话误报成未确认。
    func send(opener: TurnOpener?, stop: @escaping @MainActor () async throws -> Void, deliver: () async throws -> Void) async throws {
        try await send(opener: opener, stop: stop) { handed in
            try await deliver()
            handed()
        }
    }

    /// 同上，交出之后还要等别的（Claude Code 等确认收下要等这一轮做完）：写出这句的那一刻调 `handed`。
    /// 停不下在跑的那一轮（停止被拒、等不到收尾）抛 `previousTurnRunning`：这句确定没交出。
    func send(
        opener: TurnOpener?, stop: @escaping @MainActor () async throws -> Void, deliver: (_ handed: () -> Void) async throws -> Void
    ) async throws {
        let turn = runningTurn
        let token = UUID()
        handovers.append((token, .halting))
        defer {
            if handovers.contains(where: { $0.token == token && $0.step != .awaitingStart }) { handovers.removeAll { $0.token == token } }
            settleIfOrphaned()
        }
        do {
            try await stopPhase.run { [self] in try await halt(stop, of: turn) }
        } catch let error as CancellationError {
            throw error
        } catch {
            throw BridgeError.rejected(RejectReason.previousTurnRunning.rawValue)
        }
        step(token, to: .delivering)
        let previous = facts.turnOpener
        if let opener { open(by: opener) }
        var handedOut = false
        do {
            try await deliver { [self] in
                handedOut = true
                guard handovers.contains(where: { $0.token == token && $0.step == .delivering }) else { return }
                if phase == .handedOver { step(token, to: .awaitingStart) } else { handovers.removeAll { $0.token == token } }
                settleIfOrphaned()
            }
        } catch {
            if !handedOut { open(by: previous) } else if case .refused? = error as? BridgeError { open(by: previous) }
            throw error
        }
    }

    private func open(by opener: TurnOpener?) {
        guard facts.turnOpener != opener else { return }
        facts.turnOpener = opener
        onChange()
    }

    func abort(stop: @escaping @MainActor () async throws -> Void) async throws {
        let turn = runningTurn
        handovers = []
        stopPhase.cancelAll()
        settleIfOrphaned()
        try await stopPhase.run(cancellable: false) { [self] in try await halt(stop, of: turn) }
    }

    /// 此刻在跑的那一轮，按已收尾的轮数认（`ends.count`，这一轮收尾才变）；没在跑是 nil
    private var runningTurn: Int? { phase == .running ? ends.count : nil }

    /// 没被开始认领、没被停下清掉的才改
    private func step(_ token: UUID, to step: Handover) {
        if let index = handovers.firstIndex(where: { $0.token == token }) { handovers[index].step = step }
    }

    private func settleIfOrphaned() {
        if !handingOver, phase == .handedOver { settle() }
    }

    /// `turn` 是停止发出时抓到的在跑那一轮：停止段排队期间它已收尾（Agent 可能紧接着开了下一轮）就过期了，不发给 Agent。
    /// 已经发出、在路上时换了轮的管不到（ACP 与 Claude Code 的停止不带轮次，落在当前这一轮上）。
    /// 没抓到（歇着、换轮的话已交出）也照发、不等：开始从事件流晚到的（OpenCode、Codex）这时可能已在跑，在不在跑由各家判断，
    /// 不发的话停止报成功、这一轮照跑，再说一句也会并进它。
    private func halt(_ stop: () async throws -> Void, of turn: Int?) async throws {
        guard let turn else { return try await stop() }
        guard runningTurn == turn else { return }
        stopping = true
        stopRequests += 1
        let seen = ends.count
        do {
            try await stop()
        } catch {
            // 停止请求没被收下：这一轮照旧，之后它自己出错要报（同一轮另有请求在途的除外）。收下了却等不到收尾（下面的等待超时）的照旧算被停下
            if ends.count == seen {
                stopRequests -= 1
                if stopRequests == 0 { stopping = false }
            }
            throw error
        }
        try await ends.wait(after: seen)
    }

    private func settle() {
        phase = .idle
        facts.endTurn()
        onChange()
    }

    /// 连接断开、进程退出：等收尾的都放行，之后不再有一轮
    func closed() {
        phase = .idle
        handovers.removeAll { $0.step == .awaitingStart }
        ends.happened()
    }

    /// 按快照对齐（断线重连后）：`start` 是在跑的那一轮的开始，取会话记录里的（不晚于事件报来的同一轮的开始），nil 是歇着。错过的事件不补；
    /// 在跑的那一轮快照里已歇下、或换成了更晚开始的一轮，就是错过了它的收尾，照收尾处理（等它收尾的换轮放行、接着交出）。
    func reconcile(runningSince start: Date?) {
        tools = []
        if phase == .running, let start, start <= facts.turnStartedAt ?? .distantPast {
            return facts.startTurn(at: start)
        }
        if phase == .running { finish() }
        if let start {
            apply(.turnStarted, at: start)
            return
        }
        handovers.removeAll { $0.step == .awaitingStart }
        if !handingOver {
            phase = .idle
            facts.running = false
        }
    }
}
#endif
