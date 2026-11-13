#if os(macOS)
import CueAgent
import CueBridge
import CueStore
import CueText
import Foundation

extension CueKeeper {
    /// `said`、`images`、`delivering` 是随信封交出去的你的消息与回答，`related` 是按其中他自己说的话在会话回复里查到的（`CueTools.related`，交话的那一处查）；
    /// `answering`：承接回答你的那一轮出错后的重来。发出去之前记下送达（`hand`）。发不进去时按大脑出了问题处理（交出去的退回），返回 false。
    func wakeUp(
        _ wake: CueWake, answering: Bool = false, said: String? = nil, related: [String] = [], images: [MessageImage] = [], delivering: [UUID] = []
    ) async throws -> Bool {
        guard let shift else { return false }
        let store = self.store, now = self.now
        let mark = try await store.lastWrite()
        let changes = try await self.changes(at: now)
        let envelope = CueEnvelope.render(try await CueEnvelope.read(
            from: store, wake: wake, changes: changes, now: setup.timing.clock(), host: setup.recorder.hostID,
            language: CueInterface.current.writing(after: said), retrying: retrying.map(Self.firstLine), related: related))
        var parts = [envelope]
        if !shift.primed || renewDue(shift, now: now) {
            if shift.primed {
                do {
                    try await shift.brain.newSession()
                } catch {
                    await broke(ShownText("开不了新会话：\(ShownText(error).embedded)"))
                    return false
                }
                Self.log.notice("Cue 换新：开了新会话")
                updateShift {
                    $0.context = nil
                    $0.lastRequest = nil
                }
            }
            // 还没交给它的你的话不进对话视图：它们这次随信封交出去（`CueView` 只列已送达的）
            let views = [CueMemoryView(try await store.cueMemory()).viewText, CueView.render(try await store.cueMessages(limit: CueView.fetched))]
            parts.insert(contentsOf: views.compactMap { $0 }, at: 0)
        }
        if let said { parts.append(said) }
        let sent = parts.joined(separator: "\n"), sending = UUID()
        guard try await hand(sent, images: images, id: sending, delivering: delivering) else { return false }
        var turn = Turn(
            answersYou: wake == .message || answering || !shift.taken.isEmpty, round: beginRound(wake, sent: [sent], at: now),
            selfStarted: wake == .message ? nil : wake, delivered: shift.taken, mark: mark, stops: Self.stops(in: wake, changes))
        Self.log.notice("Cue 醒来：\(String(describing: wake).prefix(60), privacy: .public)，回复写成 \(turn.author.rawValue, privacy: .public)")
        // Cue 自己醒来的一轮醒来就写下经过那一行：为什么醒在它上面，各端马上画得出叫醒的那一下
        if !turn.answersYou {
            do {
                turn.round.row = try await store.recordCueRound(nil, startedAt: now, answersYou: false, tools: nil, wake: wake)
            } catch {
                Self.log.error("Cue 这一轮的经过没能写进资料库：\(error.localizedDescription, privacy: .public)")
            }
        }
        updateShift {
            $0.primed = true
            $0.turn = turn
            $0.taken = []
        }
        retrying = nil
        heardAt = setup.timing.awake()
        return true
    }

    /// 交给大脑（醒来与插话唯一的发出口）：先记着交出去了、写下送达，再发。记送达在先：发出后才写、写失败时下次对账会把同一句再交一次；
    /// 写下之后、发出之前崩溃，下次值班按落盘的没答上的退回（`save`）。发不进去按大脑出了问题处理，交出去的随班次退回（`retire`），返回 false。
    func hand(_ text: String, images: [MessageImage], id sending: UUID, delivering ids: [UUID]) async throws -> Bool {
        guard let shift else { return false }
        if !ids.isEmpty {
            updateShift { $0.handed[sending] = ids }
            save()
            try await store.markCueMessagesDelivered(ids)
            unfetchable.subtract(ids)
            let upload = setup.upload
            Task { await upload(ids) }
        }
        do {
            try await shift.brain.send(text, images: images, id: sending)
            return true
        } catch {
            await broke(ShownText("发不进去：\(ShownText(error).embedded)"))
            return false
        }
    }

    private static func stops(in wake: CueWake, _ due: [CueChange]) -> [CueLeft] {
        guard case .sessionActivity = wake else { return [] }
        return due.filter { [.settled, .waitingForUser, .failed].contains($0.kind) }
            .compactMap { $0.session.map { CueLeft(sessionID: $0.sessionID, since: $0.stateSince) } }
    }

    /// 这次醒来要先开新会话（换新，唯一规则；只在一次醒来开始时判断，不在一轮中途换）：上下文到了换新线，或距上一次模型请求超过提示缓存的时长（缓存已过期，接着用要把整段原价重写；
    /// 换新只写固定前缀与视图，从不更贵）。还没请求过模型的会话不换。不多跑一轮、不先写交接：实测缓存热时先写交接再换没有带来提升，交接还每次写超 600 字。
    func renewDue(_ shift: Shift, now: Date) -> Bool {
        guard let used = shift.context?.used, let last = shift.lastRequest else { return false }
        return used >= setup.timing.renewAt || now.timeIntervalSince(last) > setup.timing.cacheLifetime.seconds
    }

    /// 不在的在旁边取（`fetchAttachments`，从这台开始等起至多 `DeliveryRequest.phaseLimit`），取到了再对一次账：等文件不挡后面的话。
    /// 不从写下算：手机离线时写下、连上才到的话照样等得到附件，手机与这台的钟差也不混进来。
    /// 取不来或到点的对你说一声，话照交。
    func ready(_ pending: [CueMessage]) -> [CueMessage] {
        pending.filter { message in
            guard message.author == .known(.you), !unfetchable.contains(message.id) else { return true }
            let missing = CueFormat.attachmentKeys(in: message.text).filter { store.files.fileURL(for: $0) == nil }
            guard !missing.isEmpty else { return true }
            if fetchingFiles[message.id] == nil {
                fetchingFiles[message.id] = fetch(missing, for: message.id, until: store.timing.now().addingTimeInterval(DeliveryRequest.phaseLimit))
            }
            return false
        }
    }

    private func fetch(_ keys: [String], for message: UUID, until deadline: Date) -> Task<Void, Never> {
        let fetchFile = setup.fetchFile, timing = store.timing, files = store.files
        return Task {
            let failure: ShownText?
            do {
                switch try await fetchAttachments(Set(keys), into: files, until: { try await timing.sleepUntil(deadline) }, using: { _ = try await fetchFile($0) }) {
                case .arrived: failure = nil
                case .expired: failure = ShownText("附件到期还没传到这台 Mac")
                case .missing: failure = ShownText("附件取过了仍不在这台 Mac 上")
                }
            } catch is CancellationError {
                return
            } catch {
                failure = ShownText(error)
            }
            if let failure {
                unfetchable.insert(message)
                await say(.cue, ShownText("你发的附件没能交给我：\(failure.embedded)"))
            }
            fetchingFiles[message] = nil
            input.yield(.kick)
        }
    }

    /// 你的消息里的图，按发给会话的同一个转换取出、交给看得了图的大脑；文字里的图片引用照留（Cue 转给会话时原样写进去）。
    /// 看不了图的，图同文件一样以路径写进信封（`CueEnvelope.delivered`），这里不交。图不在这台 Mac 上，不交图并对你说一声，不悄悄丢掉。
    func images(in pending: [CueMessage], for brain: any HostedSession) async -> [MessageImage] {
        guard brain.seesImages else { return [] }
        let contents = pending.filter { $0.author == .known(.you) && CueFormat.hasAttachments($0.text) }.map { SendContent(stored: $0.text) }
        guard !contents.isEmpty else { return [] }
        do {
            return try contents.flatMap { try $0.messageImages(from: store.files) }
        } catch {
            await say(.cue, ShownText("你发的图没能交给我：\(ShownText(error).embedded)"))
            return []
        }
    }

    /// 这一轮写给你的话（回复、回答你的一轮出错）：提不提示你、一轮只响一次都在 `CueStore.replyCueRound`。
    func reply(_ text: ShownText, in turn: Turn) async {
        do {
            try await store.replyCueRound(startedAt: turn.round.startedAt, reply: text, as: turn.author, answersYou: turn.answersYou, answeredRequests: turn.delivered)
        } catch {
            Self.log.error("Cue 这一轮的话没能写进资料库：\(error.localizedDescription, privacy: .public)")
        }
    }

    func say(_ author: CueAuthor, _ text: ShownText, urgent: Bool = false) async {
        do {
            try await store.addCueMessage(author, shown: text, urgent: urgent)
        } catch {
            Self.log.error("Cue 的消息没能写进资料库：\(error.localizedDescription, privacy: .public)")
        }
    }

    func schedule(_ date: Date?) {
        guard let date else { return }
        let input = input, timing = store.timing, wake = max(date, now).addingTimeInterval(0.05)
        timer = Task {
            guard (try? await timing.sleepUntil(wake)) != nil else { return }
            input.yield(.kick)
        }
    }

    func save() {
        progress.unanswered = Array(owed.union(shift?.unanswered ?? []))
        do {
            try FileManager.default.createDirectory(at: setup.directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(progress).write(to: setup.directory.appending(path: "keeper.json"), options: .atomic)
        } catch {
            Self.log.error("Cue 的对账进度没能存下：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 交出去没答上的你的话退回没送达、重新交，连同此前没退回成的（`owed`）；退回你的话只经这里。
    /// 没写成的留在 `owed`（落盘），对账时再试（`alarm` 排着）：你的话只在答上或退回写进库之后才放下。
    func giveBack(_ ids: [UUID]) async {
        owed.formUnion(ids)
        guard !owed.isEmpty else { return }
        do {
            try await store.unmarkCueMessagesDelivered(Array(owed))
            owed = []
        } catch {
            Self.log.error("Cue 没答上的消息没能退回，过一阵再试：\(error.localizedDescription, privacy: .public)")
        }
        save()
    }

    static func retryable(_ summary: ErrorSummary) -> Bool { summary.failure.retries }

    /// 错的原文首行（信封里那一行只放得下这么多）。
    static func firstLine(_ raw: String) -> String {
        String((raw.split(whereSeparator: \.isNewline).first ?? "").prefix(200))
    }

    static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year!)-\(parts.month!)-\(parts.day!)"
    }
}
#endif
