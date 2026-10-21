#if os(macOS)
import CueStore
import Darwin
import Foundation

extension PiBridge {
    /// CuePad 重开前各会话记下的状态与计时（启动对账时从同步记录里取，`PiStateRecorder.reset`）。
    public func carryOver(_ before: [String: (state: PiWorkState, times: PiTimes)]) { carried = before }

    /// 一个会话上线（发现了它，或 CuePad 刚开了它）：之后的命令交给 `link`。同一 id 已在线时只换通道与快照，不重报出现。
    /// 状态的起点只有这一处定：重新上桥（同一 id 换了快照、重新载入扩展、CuePad 重开后接回）时粗状态（`PiWorkState.phase`）没变就沿用原来的起点，
    /// 各家接入上桥时给的"现在"不算——界面的"多久前""有新回复"与同步记录都读它。
    public func attach(_ session: PiSession, via link: any SessionLink) {
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

    /// 改一个在线会话的快照：状态或那句说明变了报 `stateChanged`，否则报 `infoChanged`；没有变化不报。不在线时什么也不做。
    public func update(_ id: PiSession.ID, _ change: (inout PiSession) -> Void) {
        guard let slot = slots.first(where: { $0.id == id }) else { return }
        var session = slot.session
        change(&session)
        replace(slot, with: session)
    }

    private func replace(_ slot: Slot, with session: PiSession) {
        let previous = slot.session
        guard session != previous else { return }
        slot.session = session
        emit(session.state != previous.state || session.detail != previous.detail ? .stateChanged(session, from: previous.state) : .infoChanged(session))
    }

    /// 改一个在线会话正在说的话（`PiDraft`）：各家接入每个增量调一次即可，刷新节奏由 `PiDraftFeed` 统一定；只改这一格的 `draft`，
    /// 不经 `changes()`（不进记录器、不进同步）。不在线时什么也不做；会话下线时随它的格子一起没了。
    public func setDraft(_ id: PiSession.ID, _ draft: PiDraft?) {
        slots.first { $0.id == id }?.offer(draft)
    }

    public func detach(_ id: PiSession.ID, reason: PiSessionEndReason) {
        controls[id] = nil
        idleTimers.removeValue(forKey: id)?.cancel()
        releasing.remove(id)
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        let session = slots.remove(at: index).session
        if reason == .reload, !session.upgrading { carried[session.sessionID] = session.carried }
        emit(.ended(session, reason: reason))
    }

    // MARK: 托管的会话

    /// 托管的会话什么时候请它退出（不算结束，发话时再接着）：同一会话在别处（终端里）也开着、自己又空闲的（两边会各写各的；正在跑一轮的等它做完、状态变化时再看）；
    /// 歇着满 `hostedIdle` 的（为自己起了进程的 Claude Code、Codex；Pi 自己计时，App 退出后照常在；OpenCode 的会话在它的服务里，没有进程要关）。
    func reviewHosted() {
        for slot in slots where slot.session.hosted && !releasing.contains(slot.id) {
            let session = slot.session
            let busy = session.state.hasPendingWork
            let elsewhere = slots.contains { $0.session.agent == session.agent && $0.sessionID == session.sessionID && !$0.session.hosted }
            if !busy && elsewhere {
                release(session.id)
            } else if session.agent == .pi || session.agent == .opencode {
                continue
            } else if busy {
                idleTimers.removeValue(forKey: session.id)?.cancel()
            } else if idleTimers[session.id] == nil {
                let id = session.id, limit = hostedIdle
                idleTimers[id] = Task { [weak self] in
                    guard (try? await Task.sleep(for: limit)) != nil else { return }
                    self?.release(id)
                }
            }
        }
    }

    private func release(_ id: PiSession.ID) {
        guard let link = controls[id], releasing.insert(id).inserted else { return }
        idleTimers.removeValue(forKey: id)?.cancel()
        Task { try? await link.end(id) }
    }
}
#endif
