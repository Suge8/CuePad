#if os(macOS)
import CuePi
import CueStore
import Foundation

extension VoiceService {
    func startLocal(source: VoicePeer.Source, name: String, makeCall: @MainActor (VoiceCall.Dependencies) -> VoiceCall) {
        guard call?.isLive != true, remote == nil else { return }
        let call = obtainCall(name: name, source: source, makeCall: makeCall)
        issue = nil
        projectionReaders.removeAll()
        call.reconnect()
        session = VoiceSessionID(call.session)
        observeCall(call)
    }

    private func obtainCall(name: String, host: String? = nil, source: VoicePeer.Source = .microphone,
                            makeCall: @MainActor (VoiceCall.Dependencies) -> VoiceCall = VoiceCall.init) -> VoiceCall {
        let services = services
        let tell: (String) async throws -> UUID = { [weak services] text in
            guard let services else { throw CancellationError() }
            return try await services.recordVoiceSpeech(text, host: host)
        }
        if let call {
            call.dependencies.tell = tell
            call.dependencies.cueName = name
            call.dependencies.source = source
            return call
        }
        let value = makeCall(.init(
            access: { [weak services] in
                guard let services else { throw CancellationError() }
                if let file = DebugHooks.voiceToken {
                    guard let access = CodexAccess(token: try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        throw CodexAccessError.signedOut
                    }
                    return access
                }
                return try await services.agents.integration.codexAccess(executable: services.agents.executable(.codex))
            },
            tell: tell, store: services.store, cueName: name, source: source))
        call = value
        return value
    }

    func receiveSignal(_ received: VoiceReceivedSignal) async {
        if case .command(let command) = received.payload {
            receiveCommand(command, header: received.header)
            return
        }
        if case .media(.offer(let offer)) = received.payload {
            await acceptOffer(offer, header: received.header)
            return
        }
        let header = received.header
        if case .media(.resume(let ask)) = received.payload {
            if ask { answer(header) }
            return
        }
        guard let remote, remote.session == header.session, remote.link == .bound(local: header.recipient, peer: header.sender) else { return }
        switch received.payload {
        case .media(.event(.connected)):
            remote.connected = true
            remote.onEvent(.connected)
        case .media(.event(.ended(let reason))), .media(.hangup(let reason)): remote.departed(reason)
        default: remote.departed(.protocolRejected)
        }
    }

    /// 换绑的唯一入口：Mac 这一通（含已在这边先结束的）从这台手机来的任何一帧（命令、resume、普通帧；等着时同一租约的也算），
    /// 媒体桥换到这对租约（命令来源核对、挂断、媒体事件都按它认），这一通已有的命令结果按原命令身份补送过去，
    /// 投影推送重新登记到这里并补发当前投影：宽限期里错过的更新由这份整份状态补齐，Mac 先结束的由此把真实结束原因带给手机。
    func rebind(_ header: VoiceSignalHeader) {
        guard let call, VoiceSessionID(call.session) == header.session else { return }
        let device = header.sender.device, pair = VoiceLink.bound(local: header.recipient, peer: header.sender)
        var changed = false
        if let remote, remote.session == header.session {
            guard remote.link.peerDevice == device else { return }
            if remote.link != pair {
                remote.link = pair
                changed = true
                call.mark("relinked by \(header.purpose)")
                for (id, outcome) in remote.results {
                    Task { await sendResult(.init(command: id, outcome: outcome), session: remote.session, to: header.sender) }
                }
            }
        }
        if let reader = projectionReaders[device], reader.sender == header.sender, reader.recipient == header.recipient {} else {
            projectionReaders[device] = header
            changed = true
        }
        guard changed, let value = projection, value.session == header.session, let reader = projectionReaders[device] else { return }
        Task { if await !sendProjection(value, to: reader) { retryProjection(to: reader) } }
    }

    func waitsForRelink(_ session: VoiceSessionID) -> Bool { false }

    /// 手机问"你还在吗"（`VoiceMediaSignal.resume`）：照答。换绑与补发投影已在 `rebind` 做过。
    private func answer(_ header: VoiceSignalHeader) {
        guard let call, VoiceSessionID(call.session) == header.session, let signaling else { return }
        Task {
            let scope = VoiceOperationScope()
            defer { scope.end() }
            do {
                try await scope.perform(within: .seconds(2)) {
                    try await signaling.sendVoice(.media(signal: .resume(ask: false)), session: header.session, to: header.sender)
                }
            } catch { AppServices.log.error("Voice resume answer not sent: \(String(describing: error))") }
        }
    }

    private func acceptOffer(_ offer: VoiceOffer, header: VoiceSignalHeader) async {
        guard let signaling else { return }
        guard call?.isLive != true, remote == nil else {
            await rejectOffer(header, issue: .busy)
            return
        }
        // 先占住 owner 再读库，第二个设备不能在授权等待期间抢占同一 VoiceCall。
        let media = VoiceRemoteMedia(header: header, offer: offer, signaling: signaling)
        remote = media
        do {
            let profile = try await services.store.cueProfile()
            guard remote === media, media.available else { return }
            guard profile?.activeHost == services.hostID else {
                await rejectOffer(header, issue: .cueUnavailable)
                remote = nil
                return
            }
            let call = obtainCall(name: profile?.name ?? CueProfile.defaultName, host: services.hostID)
            issue = nil
            session = header.session
            projectionReaders = [header.sender.device: header]
            call.reconnect(session: header.session.rawValue, media: media)
            observeCall(call)
        } catch {
            await rejectOffer(header, issue: .storageUnavailable)
            if remote === media { remote = nil }
        }
    }

    private func rejectOffer(_ header: VoiceSignalHeader, issue: VoiceIssue) async {
        do {
            try await signaling?.sendVoice(.projection(value: .init(session: header.session, phase: .failed(issue), requests: [], replies: [], executions: [])),
                                           session: header.session, to: header.sender)
        } catch { self.issue = .ended(.networkFailed) }
    }

    private func observeCall(_ call: VoiceCall) {
        observing?.cancel()
        observing = Task { [weak self] in
            for await result in Observations({ [weak self] in self.map { service in Result { try service.macProjection(call) } } }) {
                guard let self, let result, !Task.isCancelled else { return }
                // 先于投影：投影读失败时也要放开手机那通，否则之后的来电一直被当成占线
                if !call.isLive, self.call === call { self.remote = nil }
                let value: VoiceCallProjection
                switch result {
                case .success(let projection): value = projection
                case .failure:
                    self.issue = .storageUnavailable
                    call.inputs.continuation.yield(.failed(.other("Voice projection storage unavailable")))
                    continue
                }
                guard self.call === call, self.session == value.session else { return }
                self.setProjection(value)
                for reader in self.projectionReaders.values where reader.session == value.session {
                    if await self.sendProjection(value, to: reader) { self.projectionRetries.removeValue(forKey: reader.sender.device)?.cancel() }
                    else { self.retryProjection(to: reader) }
                }
            }
        }
    }

    private func sendProjection(_ value: VoiceCallProjection, to reader: VoiceSignalHeader) async -> Bool {
        let sending = VoiceOperationScope()
        defer { sending.end() }
        do {
            try await sending.perform(within: .seconds(2)) {
                guard let signaling = self.signaling else { throw VoicePageError.unavailable }
                try DebugHooks.voiceProjectionSend()
                try await signaling.sendVoice(.projection(value: value), session: reader.session, to: reader.sender)
            }
            return true
        } catch {
            AppServices.log.error("Voice projection not sent: \(String(describing: error))")
            return false
        }
    }

    /// 一次没发出去不等于链路断（断没断只认中转的关闭、离开与拒收）：每秒补发最新的那份，直到发出、有更新的发出去了，或这个接收者没了；
    /// 不补的话，之后没有新变化时手机一直停在旧状态。
    private func retryProjection(to reader: VoiceSignalHeader) {
        let device = reader.sender.device
        guard projectionRetries[device] == nil else { return }
        projectionRetries[device] = Task { [weak self] in
            while (try? await Task.sleep(for: .seconds(1))) != nil {
                guard let self, self.projectionReaders[device] == reader, let value = self.projection, value.session == reader.session else { break }
                if await self.sendProjection(value, to: reader) { break }
            }
            if let self, !Task.isCancelled { self.projectionRetries[device] = nil }
        }
    }

    func connectionClosed(local: VoiceEndpoint?, peer: VoiceEndpoint?, reason: VoiceEndReason) async {
        guard let remote, case .bound(let bound, let phone) = remote.link,
              local == nil || bound == local, peer == nil || phone == peer else { return }
        if remote.connected, call?.isLive == true, VoiceLink.canRelink(after: reason) { return relink(remote, phone: phone.device, reason: reason) }
        remote.departed(reason)
        if call?.isLive != true { self.remote = nil }
    }

    /// 等手机回来；Mac 自己的中转断了时手机未必察觉，所以这边也每秒向手机的当前租约问一次（resume ask），手机回的任何一帧都算回来了。
    /// 宽限期满还没回来按断开时的原因结束；媒体或用户先结束时 `departed`/`close` 结束 remote.scope，这里的等待随之停下。
    private func relink(_ remote: VoiceRemoteMedia, phone: VoiceDeviceID, reason: VoiceEndReason) {
        let until = ContinuousClock.now + VoiceSignalFormat.relinkGrace
        remote.link = .relinking(peer: phone, until: until, reason: reason)
        call?.mark("relinking \(reason.rawValue)")
        remote.scope.spawn { [weak self] in
            await self?.reach(phone, until: until, done: { remote.link.isBound }) { signaling, peer in
                try await signaling.sendVoice(.media(signal: .resume(ask: true)), session: remote.session, to: peer)
            }
            guard !remote.link.isBound, !Task.isCancelled else { return }
            remote.departed(reason)
        }
    }

    func end(reason: VoiceEndReason = .hungUp) async {
        guard let call, call.isLive else { return }
        if let remote { remote.onEvent(.ended(reason)) } else { call.hangUp() }
        for await phase in Observations({ call.phase }) {
            switch phase {
            case .ended, .failed: return
            default: break
            }
        }
    }
}
#endif
