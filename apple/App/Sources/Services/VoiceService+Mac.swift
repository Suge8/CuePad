#if os(macOS)
import CueBridge
import CueStore
import Foundation

extension VoiceService {
    func startLocal(source: VoicePeer.Source) {
        guard call?.isLive != true, remote == nil else { return }
        let call = newCall(source: source)
        projectionReaders.removeAll()
        call.start()
        observeCall(call)
    }

    private func newCall(host: String? = nil, source: VoicePeer.Source = .microphone) -> VoiceCall {
        preview.stop()
        let services = services
        let tell: (String, UUID) async throws -> UUID = { [weak services] text, command in
            guard let services else { throw CancellationError() }
            return try await services.recordVoiceSpeech(text, command: command, host: host)
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
                let codex = if let debug = DebugHooks.voiceCodex { debug } else { await services.agents.executable(.codex) }
                return try await services.agents.integration.codexAccess(executable: codex)
            },
            source: source), VoiceRecord(store: services.store, tell: tell))
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
        guard let remote, remote.leg.session == header.session, remote.leg.link == .bound(local: header.recipient, peer: header.sender) else { return }
        switch received.payload {
        case .media(.event(.connected)):
            remote.leg.connected = true
            remote.onEvent(.connected)
        case .media(.event(.ended(let reason))), .media(.hangup(let reason)): remote.departed(reason)
        default: remote.departed(.protocolRejected)
        }
    }

    func rebind(_ header: VoiceSignalHeader) {
        guard let call, VoiceSessionID(call.session) == header.session else { return }
        let device = header.sender.device
        var changed = false
        if let remote, remote.leg.session == header.session {
            guard remote.leg.link?.peerDevice == device else { return }
            if remote.leg.rebind(header) {
                changed = true
                call.mark("relinked by \(header.purpose)")
                for (id, outcome) in remote.results {
                    Task { await sendResult(.init(command: id, outcome: outcome), session: header.session, to: header.sender) }
                }
            }
        }
        if let reader = projectionReaders[device], reader.sender == header.sender, reader.recipient == header.recipient {} else {
            projectionReaders[device] = header
            changed = true
        }
        guard changed, projection?.session == header.session else { return }
        pushProjection(to: device)
    }

    func waitsForRelink(_ session: VoiceSessionID) -> Bool { false }

    func hangUp() async { call?.hangUp() }

    func setMuted(_ value: Bool) async throws {
        guard canMute, let call else { throw VoiceIssue.busy }
        call.setMuted(value)
    }

    private func answer(_ header: VoiceSignalHeader) {
        guard let call, VoiceSessionID(call.session) == header.session, let signaling else { return }
        Task {
            let scope = VoiceOperationScope()
            defer { scope.end() }
            do {
                try await scope.perform(within: VoiceTiming.send) {
                    try await signaling.sendVoice(.media(signal: .resume(ask: false)), session: header.session, to: header.sender)
                }
            } catch { AppServices.log.error("Voice resume answer not sent: \(String(describing: error))") }
        }
    }

    private func acceptOffer(_ offer: VoiceOffer, header: VoiceSignalHeader) async {
        guard let signaling else { return }
        guard offer.version == VoiceSignalFormat.callVersion else {
            AppServices.log.notice("Voice offer from signal version \(offer.version), this Mac speaks \(VoiceSignalFormat.callVersion)")
            return await rejectOffer(header, issue: .relayUnsupported)
        }
        guard call?.isLive != true, remote == nil else {
            await rejectOffer(header, issue: .busy)
            return
        }
        let media = VoiceRemoteMedia(header: header, offer: offer, signaling: signaling)
        remote = media
        do {
            let profile = try await services.store.cueProfile()
            guard remote === media else { return }
            guard media.available else { return release(media) }
            guard profile?.activeHost == services.hostID else {
                release(media)
                await rejectOffer(header, issue: .cueUnavailable)
                return
            }
            let call = newCall(host: services.hostID)
            projectionReaders = [header.sender.device: header]
            call.ended = { [weak self, weak media] in if let media { self?.release(media) } }
            call.start(session: header.session.rawValue, media: media)
            observeCall(call)
        } catch {
            release(media)
            await rejectOffer(header, issue: .storageUnavailable)
        }
    }

    private func release(_ media: VoiceRemoteMedia) {
        if remote === media { remote = nil }
    }

    private func rejectOffer(_ header: VoiceSignalHeader, issue: VoiceIssue) async {
        do {
            let value = VoiceCallProjection(session: header.session, phase: .failed(issue), requests: [], replies: [])
            try await signaling?.sendVoice(.projection(value: value), session: header.session, to: header.sender)
        } catch { AppServices.log.error("Voice offer rejection not sent: \(String(describing: error), privacy: .public)") }
    }

    private func observeCall(_ call: VoiceCall) {
        observing?.cancel()
        observing = Task { [weak self] in
            for await result in Observations({ [weak self] in self.map { service in Result { try service.fullProjection(call) } } }) {
                guard let self, let result, !Task.isCancelled else { return }
                let value: VoiceCallProjection
                switch result {
                case .success(let projection): value = projection
                case .failure:
                    call.inputs.continuation.yield(.failed(.other("Voice projection storage unavailable")))
                    continue
                }
                guard self.call === call else { return }
                self.setProjection(value)
                for (device, reader) in self.projectionReaders where reader.session == value.session { self.pushProjection(to: device) }
            }
        }
    }

    private func sendProjection(_ value: VoiceCallProjection, to reader: VoiceSignalHeader) async -> Bool {
        let sending = VoiceOperationScope()
        defer { sending.end() }
        do {
            try await sending.perform(within: VoiceTiming.send) {
                guard let signaling = self.signaling else { throw VoiceSignalError.unavailable }
                try DebugHooks.voiceProjectionSend()
                try await signaling.sendVoice(.projection(value: value.bounded()), session: reader.session, to: reader.sender)
            }
            return true
        } catch {
            AppServices.log.error("Voice projection not sent: \(String(describing: error))")
            return false
        }
    }

    private func pushProjection(to device: VoiceDeviceID) {
        guard projectionSenders[device] == nil else { return }
        projectionSenders[device] = Task { [weak self] in
            var sent: (VoiceCallProjection, VoiceSignalHeader)?
            while let self, !Task.isCancelled {
                guard let reader = self.projectionReaders[device], let value = self.projection, value.session == reader.session,
                      sent.map({ $0.0 != value || $0.1 != reader }) ?? true else {
                    self.projectionSenders[device] = nil
                    return
                }
                if await self.sendProjection(value, to: reader) { sent = (value, reader) }
                else if (try? await Task.sleep(for: .seconds(1))) == nil { return }
            }
        }
    }

    func connectionClosed(local: VoiceEndpoint?, peer: VoiceEndpoint?, reason: VoiceEndReason) async {
        guard let remote, remote.leg.carries(local: local, peer: peer) else { return }
        await remote.leg.closed(reason, signaling: signaling, canWait: call?.isLive == true)
    }
}
#endif
