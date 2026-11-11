#if os(macOS)
import CueStore
import Darwin
import Foundation

extension Bridge {
    /// 启动对账时从同步记录里取（`CueStore.launchMac`）。
    public func carryOver(_ before: [String: (state: WorkState, times: SessionTimes)]) { carried = before }

    /// 同一 id 已在线时只换通道与快照，不重报出现。
    /// 状态的起点只有这一处定：重新上桥（同一 id 换了快照、重新载入扩展、CuePad 重开后接回）时粗状态（`WorkState.phase`）没变就沿用原来的起点，
    /// 各家接入上桥时给的"现在"不算——界面的"多久前""有新回复"与同步记录都读它。
    public func attach(_ session: Session, via link: any SessionLink) {
        controls[session.id] = link
        var session = session
        let before = slots.first { $0.id == session.id && !$0.session.upgrading }.map(\.session.carried)
            ?? (session.upgrading ? nil : carried.removeValue(forKey: session.sessionID))
        if let before, before.state.phase == session.state.phase {
            session.stateSince = before.times.stateSince
            session.busySince = before.times.busySince ?? session.busySince
        }
        guard let slot = slots.first(where: { $0.id == session.id }) else {
            slots.append(Slot(session))
            return emit(.appeared(session))
        }
        replace(slot, with: session)
    }

    /// 历史索引读到的会话名放到在线的同一会话上：各家自己起的、改的名字有的只落在文件里（Claude Code 的 `ai-title`、Grok、Codex），
    /// 这是它们到在线会话的唯一入口。名字这次变了才换（文件落后于接入报来的改名时不倒回去），在线的还没名字时补上（CuePad 重开后接回）。
    public func read(_ update: HistoryUpdate) {
        guard let name = update.history.name else { return }
        for slot in slots where slot.session.agent == update.agent && slot.sessionID == update.sessionID && (update.renamed || slot.session.name == nil) {
            self.update(slot.id) { $0.name = name }
        }
    }

    public func update(_ id: Session.ID, _ change: (inout Session) -> Void) {
        guard let slot = slots.first(where: { $0.id == id }) else { return }
        var session = slot.session
        change(&session)
        replace(slot, with: session)
    }

    private func replace(_ slot: Slot, with session: Session) {
        let previous = slot.session
        guard session != previous else { return }
        slot.session = session
        emit(session.state != previous.state || session.detail != previous.detail ? .stateChanged(session, from: previous.state) : .infoChanged(session))
    }

    /// 改一个在线会话正在说的话（`LiveDraft`）：各家接入每个增量调一次即可，刷新节奏由 `LiveDraftFeed` 统一定；只改这一格的 `draft`，
    /// 不经 `changes()`（不进记录器、不进同步）。不在线时什么也不做；会话下线时随它的格子一起没了。
    public func setDraft(_ id: Session.ID, _ draft: LiveDraft?) {
        slots.first { $0.id == id }?.offer(draft)
    }

    /// 托管会话的各家接入都经这里，别的事件与桥无关。
    public func show(_ event: TurnEvent, in id: Session.ID) {
        switch event {
        case .speaking(let draft): setDraft(id, draft)
        case .context(let used, let window?): update(id) { $0.context = ContextUsage(tokens: used, window: window) }
        default: break
        }
    }

    public func detach(_ id: Session.ID, reason: SessionEndReason) {
        controls[id] = nil
        idleTimers.removeValue(forKey: id)?.cancel()
        releasing.remove(id)
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        let session = slots.remove(at: index).session
        if reason == .reload, !session.upgrading { carried[session.sessionID] = session.carried }
        emit(.ended(session, reason: reason))
    }

    /// 歇着满 `hostedIdle` 时请它退出（不算结束，发话时再接着；`AgentFacts.releasesIdleHosted`）。
    func reviewHosted() {
        for slot in slots where !releasing.contains(slot.id) {
            let session = slot.session
            let busy = session.state.hasPendingWork
            if !session.agent.facts.releasesIdleHosted {
                continue
            } else if busy {
                idleTimers.removeValue(forKey: session.id)?.cancel()
            } else if idleTimers[session.id] == nil {
                let id = session.id, limit = hostedIdle, timing = timing
                idleTimers[id] = Task { [weak self] in
                    guard (try? await timing.sleep(limit)) != nil else { return }
                    self?.release(id)
                }
            }
        }
    }

    /// 请它退出；失败（含 Pi 扩展的确认超时 `ackTimeout`）就摘掉标记，下次审查（任何状态变化）再请一次。
    private func release(_ id: Session.ID) {
        guard let link = controls[id], releasing.insert(id).inserted else { return }
        idleTimers.removeValue(forKey: id)?.cancel()
        Task {
            do { try await link.end(id) } catch { releasing.remove(id) }
        }
    }
}
#endif
