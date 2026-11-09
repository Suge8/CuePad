import AVFoundation
@preconcurrency import WebRTC

/// 一通电话一份原生 WebRTC 连接，声音由 `VoiceAudio` 进出；关闭即刻停下声音与连接，不复用。所有者是通话服务。
/// offer 不等 ICE 收集：服务端是 ICE-lite，由本机发起连通检查，SDP 里不必带候选。
/// 持续收集候选：Wi-Fi 与蜂窝切换时在新网络上找回同一连接。断开（`disconnected`）后等 `grace`，回到 connected 就接着通，
/// 到期仍没回来按 mediaFailed 结束；`closed` 立刻结束。不等 WebRTC 自己报 failed：M157 断开后约 65 秒才报，
/// `iceInactiveTimeout` 改不了这个时刻（对端静默或关闭，配不配都在断开后约 73 秒 failed，实测）。
final class VoicePeer: NSObject, VoiceMedia {
    static let sampleCount = 36
    enum Source { case microphone, fixture(VoiceFixture) }
    enum Side: String { case input, output }
    enum Event: Equatable {
        case connected
        case ended(VoiceEndReason)
        case level(Side, loud: Bool, peak: Double)
        case sample(Side, peak: Double)
    }
    var onEvent: (Event) -> Void = { _ in }
    private let source: Source
    private let audio: VoiceAudio
    private let factory: RTCPeerConnectionFactory
    private var connection: RTCPeerConnection?
    private var track: RTCAudioTrack?
    private var connected = false
    private var closed = false
    private var reconnecting: Task<Void, Never>?
    /// 断开后等多久：短的网络抖动、Wi-Fi 换蜂窝的 ICE 重选都在几秒内回到 connected（对端停 4 秒再恢复，实测自己回来）。
    static let grace: Duration = .seconds(8)

    init(source: Source = .microphone) {
        self.source = source
        audio = VoiceAudio(source: source)
        factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: audio.device)
    }

    func offer() async throws -> String {
        if case .microphone = source, !(await AVAudioApplication.requestRecordPermission()) { throw VoicePeerError.microphoneDenied }
        guard !closed else { throw CancellationError() }
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let none = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: config, constraints: none, delegate: self) else { throw VoicePeerError.unavailable }
        self.connection = connection
        try audio.start { [weak self] event in self?.emit(event) }
        // 回声消除、降噪、增益已由系统的语音处理做过（文件声源不需要），WebRTC 再做一遍只会互相打架
        let processing = ["googEchoCancellation", "googAutoGainControl", "googNoiseSuppression", "googHighpassFilter"]
        let track = factory.audioTrack(with: factory.audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: Dictionary(uniqueKeysWithValues: processing.map { ($0, "false") }), optionalConstraints: nil)), trackId: "cue")
        self.track = track
        connection.add(track, streamIds: ["cue"])
        let offer = try await connection.offer(for: none)
        try await connection.setLocalDescription(offer)
        guard !closed else { throw CancellationError() }
        return offer.sdp
    }

    func accept(answer: String) async throws {
        guard let connection else { throw CancellationError() }
        try await connection.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer))
    }

    func setMuted(_ muted: Bool) async throws { track?.isEnabled = !muted }

    func close() async {
        guard !closed else { return }
        closed = true
        reconnecting?.cancel()
        audio.stop()
        connection?.close()
        connection = nil
        track = nil
    }

    private func emit(_ event: Event) {
        guard !closed else { return }
        onEvent(event)
    }

    private func changed(_ state: RTCPeerConnectionState) {
        if state != .disconnected {
            reconnecting?.cancel()
            reconnecting = nil
        }
        switch state {
        case .connected where !connected:
            connected = true
            emit(.connected)
        case .disconnected where reconnecting == nil:
            reconnecting = Task { [weak self] in
                guard (try? await Task.sleep(for: Self.grace)) != nil else { return }
                self?.emit(.ended(.mediaFailed))
            }
        case .failed, .closed: emit(.ended(.mediaFailed))
        default: break
        }
    }
}

extension VoicePeer: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor in self.changed(newState) }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// `unavailable`：WebRTC 没给出连接，或它的音频设备还没接上（`VoiceAudioDevice.link`）。
enum VoicePeerError: Error { case microphoneDenied, unavailable }
