import CueStore
import Foundation
import Observation
import os

/// AppServices 持有唯一通话 owner；页面离开、App 进后台与锁屏都不结束通话（iOS 声明了后台音频），只有挂断、中断或连接断了才结束。
/// Mac 投影决定业务阶段；本机麦克风、静音确认和电平从不上传，也不据此推断远端正在处理或朗读。
@Observable final class VoiceService {
    @ObservationIgnored unowned let services: AppServices
    @ObservationIgnored let signaling: (any VoiceSignaling)?
    private(set) var projection: VoiceCallProjection?
    var availability: VoiceRelayAvailability
    var commandResults: [VoiceCommand.ID: VoiceCommandResult.Outcome] = [:]
    let preview = VoicePreview()
    @ObservationIgnored var pending: [VoiceCommand.ID: Pending] = [:]
    struct Pending {
        let session: VoiceSessionID
        let peer: VoiceEndpoint
        let local: VoiceEndpoint
        let finish: @MainActor @Sendable (Result<VoiceCommandResult.Outcome, Error>) -> Void
    }
    #if os(macOS)
    var call: VoiceCall?
    /// 测试与调试换掉付费模型与设备的接缝
    @ObservationIgnored var makeCall: @MainActor (VoiceCall.Dependencies, VoiceRecord) -> VoiceCall = DebugHooks.makeVoiceCall
    var session: VoiceSessionID? { call.map { VoiceSessionID($0.session) } }
    /// 只登记当前租约的展示接收者，挂断后仍可收更新；不保留业务副本。
    @ObservationIgnored var projectionReaders: [VoiceDeviceID: VoiceSignalHeader] = [:]
    @ObservationIgnored var remote: VoiceRemoteMedia?
    @ObservationIgnored var observing: Task<Void, Never>?
    @ObservationIgnored var commands: [VoiceCommand.ID: Task<VoiceCommandResult.Outcome, Never>] = [:]
    @ObservationIgnored var projectionRetries: [VoiceDeviceID: Task<Void, Never>] = [:]
    #else
    var issue: VoiceIssue?
    var session: VoiceSessionID?
    @ObservationIgnored let makeMedia: () -> any VoiceMedia
    @ObservationIgnored var phone: VoicePhoneSession?
    @ObservationIgnored var phoneBinding: (session: VoiceSessionID, local: VoiceEndpoint, peer: VoiceEndpoint)?
    /// 本机媒体终态不改写 Mac 的业务投影。
    var phoneEnd: VoiceCallProjection.Phase?
    var muted = false
    var muting = false
    var closing: Bool { phone?.cleanup != nil }
    var inputSamples: [Double] = []
    var outputSamples: [Double] = []
    var outputActive = false
    #endif

    #if os(iOS)
    init(services: AppServices, signaling: (any VoiceSignaling)?,
         makeMedia: @escaping () -> any VoiceMedia = { VoicePeer(source: DebugHooks.phoneVoiceSource) }) {
        self.services = services
        self.signaling = signaling
        self.makeMedia = makeMedia
        availability = signaling?.voiceAvailability ?? .unsupported
    }
    #else
    init(services: AppServices, signaling: (any VoiceSignaling)?) {
        self.services = services
        self.signaling = signaling
        availability = signaling?.voiceAvailability ?? .unsupported
    }
    #endif

    isolated deinit {
        #if os(macOS)
        observing?.cancel()
        projectionRetries.values.forEach { $0.cancel() }
        #else
        phone?.scope.end()
        #endif
    }

    func cancel() {
        #if os(macOS)
        observing?.cancel()
        projectionRetries.values.forEach { $0.cancel() }
        observing = nil
        call?.hangUp()
        #else
        Task { await end() }
        #endif
        failPending { _ in true }
        #if os(iOS)
        revokeProjection()
        #endif
    }

    var phase: VoiceCallProjection.Phase? {
        #if os(iOS)
        if let issue { return .failed(issue) }
        // 先读结束再看在不在关：phone 不在观察里，`finish` 撤下 phone 后只改 phoneEnd，关着时没读过它的视图会一直停在"正在结束"
        let ended = phoneEnd
        if closing { return .closing }
        if let ended { return ended }
        #endif
        return projection?.phase ?? (session == nil ? nil : .connecting)
    }

    var startUnavailableReason: VoiceIssue? {
        guard canStart else { return .busy }
        #if os(iOS)
        return switch availability {
        case .unsupported: .relayUnsupported
        case .unavailable: .macUnavailable
        case .ready: nil
        }
        #else
        return nil
        #endif
    }

    /// 通话还在（连接中、通着或正在关）：中转为它留着，进后台不断开（`AppServices.prepareForBackground`）。
    var isLive: Bool {
        #if os(macOS)
        call?.isLive == true
        #else
        phone != nil
        #endif
    }

    /// 试听与通话互斥：通话在连、通着或在关时不放，开始一通先停试听。
    var canPreview: Bool { canStart && !isLive }

    func playPreview(_ voice: CueVoice) throws {
        guard canPreview else { return }
        try preview.play(voice)
    }

    var canStart: Bool {
        switch phase {
        case nil, .failed, .ended: true
        default: false
        }
    }

    var isMuted: Bool {
        #if os(macOS)
        call?.isMuted ?? false
        #else
        muted
        #endif
    }

    var canMute: Bool {
        #if os(macOS)
        remote == nil && call?.canMute == true
        #else
        phone?.leg.connected == true && !closing && !muting
        #endif
    }

    var samples: [Double] {
        #if os(macOS)
        call?.samples ?? []
        #else
        outputActive ? outputSamples : (muted ? [] : inputSamples)
        #endif
    }

    var response: VoiceCallProjection.Response {
        #if os(iOS)
        if phoneEnd != nil { return .none }
        #endif
        return projection?.response ?? .none
    }

    var canRepeat: Bool {
        #if os(macOS)
        call?.canRepeat == true
        #else
        phone?.leg.connected == true && !closing && phone?.id == projection?.session && projection?.canRepeat == true
        #endif
    }

    func setProjection(_ value: VoiceCallProjection?) { projection = value }

    func receive(_ event: VoiceRelayEvent) async {
        switch event {
        case .received(let received):
            // 换绑只认这一处：同一设备、同一通话从新租约来的任何一帧（命令、结果、媒体）都说明对端回来了
            rebind(received.header)
            if case .commandResult(let result) = received.payload {
                if let wait = pending[result.command], wait.session == received.header.session,
                   wait.peer == received.header.sender, wait.local == received.header.recipient {
                    pending[result.command] = nil
                    wait.finish(.success(result.outcome))
                }
                return
            }
            await receiveSignal(received)
        case .localClosed(let endpoint, let reason):
            #if os(macOS)
            projectionReaders = projectionReaders.filter { $0.value.recipient != endpoint }
            #else
            revokeProjection(local: endpoint)
            #endif
            await connectionClosed(local: endpoint, peer: nil, reason: reason)
            failPending { $0.local == endpoint && !waitsForRelink($0.session) }
        case .peerClosed(let endpoint, let departure):
            #if os(macOS)
            projectionReaders = projectionReaders.filter { $0.value.sender != endpoint }
            #else
            revokeProjection(peer: endpoint)
            #endif
            await connectionClosed(local: nil, peer: endpoint, reason: departure == .replaced ? .leaseReplaced : .peerLeft)
            failPending { $0.peer == endpoint && !waitsForRelink($0.session) }
        case .rejected(let header, let reason):
            switch header.purpose {
            case .media:
                guard header.session == session else { return }
                let gone = reason == .leaseMismatch || reason == .unavailable
                await connectionClosed(local: header.sender, peer: header.recipient, reason: gone ? .peerLeft : .protocolRejected)
            case .command(let id):
                guard let wait = pending[id], wait.session == header.session, wait.local == header.sender, wait.peer == header.recipient else { return }
                pending[id] = nil
                wait.finish(.failure(VoiceSignalError.rejected(reason)))
            case .commandResult:
                AppServices.log.error("Voice result rejected by Relay: \(reason.rawValue)")
            }
        case .availability(let value):
            availability = value
            #if os(iOS)
            if case .ready = value {} else { revokeProjection() }
            #endif
        }
    }

    func failPending(_ matches: (Pending) -> Bool) {
        for (id, wait) in pending where matches(wait) {
            pending[id] = nil
            wait.finish(.failure(VoiceSignalError.leaseChanged))
        }
    }
}
