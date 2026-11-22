#if os(macOS)
import CueStore
import Darwin
import Foundation

extension Bridge {
    public func carryOver(_ before: [String: (state: WorkState, times: SessionTimes)]) { carried = before }

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
            session = compacting(session, after: nil)
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
        let session = compacting(session, after: previous)
        guard session != previous else { return }
        slot.session = session
        if previous.state.isTurnRunning != session.state.isTurnRunning { slot.turn(running: session.state.isTurnRunning) }
        emit(session.state != previous.state || session.detail != previous.detail ? .stateChanged(session, from: previous.state) : .infoChanged(session))
    }

    public func setDraft(_ id: Session.ID, _ draft: LiveDraft?) {
        slots.first { $0.id == id }?.offer(draft)
    }

    public func show(_ event: TurnEvent, in id: Session.ID) {
        switch event {
        case .speaking(let draft): setDraft(id, draft)
        case .context(let used, let window?): update(id) { $0.context = ContextUsage(tokens: used, window: window) }
        default: break
        }
    }

    private func compacting(_ session: Session, after previous: Session?) -> Session {
        guard let paths, let compactsAt = session.agent.facts.compactsAt, var context = session.context else { return session }
        var session = session
        let key = session.model?.key
        let before = previous?.context
        let same = before?.window == context.window && before?.tokens == context.tokens && previous?.model?.key == key
        context.compactAt = same ? before?.compactAt : compactsAt(context.window, key, paths).flatMap { $0 > 0 ? $0 : nil }
        session.context = context
        return session
    }

    public func detach(_ id: Session.ID, reason: SessionEndReason) {
        controls[id] = nil
        idleTimers.removeValue(forKey: id)?.cancel()
        releasing.remove(id)
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        let session = slots.remove(at: index).session
        emit(.ended(session, reason: reason))
    }

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

    private func release(_ id: Session.ID) {
        guard let link = controls[id], releasing.insert(id).inserted else { return }
        idleTimers.removeValue(forKey: id)?.cancel()
        Task {
            do { try await link.end(id) } catch { releasing.remove(id) }
        }
    }
}
#endif
