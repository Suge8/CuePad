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
        guard let remote, remote.header.session == received.header.session,
              remote.header.sender == received.header.sender, remote.header.recipient == received.header.recipient else { return }
        switch received.payload {
        case .media(.event(.connected)): remote.onEvent(.connected)
        case .media(.event(.ended(let reason))), .media(.hangup(let reason)): remote.departed(reason)
        default: remote.departed(.protocolRejected)
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
                    let sending = VoiceOperationScope()
                    do {
                        try await sending.perform(within: .seconds(2)) {
                            guard let signaling = self.signaling else { throw VoicePageError.unavailable }
                            try await signaling.sendVoice(.projection(value: value), session: reader.session, to: reader.sender)
                        }
                    } catch {
                        guard !Task.isCancelled, self.call === call, self.session == value.session else { return }
                        if self.projectionReaders[reader.sender.device] == reader { self.projectionReaders[reader.sender.device] = nil }
                        if let remote = self.remote, remote.header.session == reader.session,
                           remote.header.sender == reader.sender, remote.header.recipient == reader.recipient { remote.departed(.networkFailed) }
                    }
                    sending.end()
                }
                guard !Task.isCancelled, self.call === call, self.session == value.session else { return }
                if !call.isLive { self.remote = nil }
            }
        }
    }

    func connectionClosed(local: VoiceEndpoint?, peer: VoiceEndpoint?, reason: VoiceEndReason) async {
        guard let remote, local == nil || remote.header.recipient == local, peer == nil || remote.header.sender == peer else { return }
        remote.departed(reason)
        if call?.isLive != true { self.remote = nil }
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
