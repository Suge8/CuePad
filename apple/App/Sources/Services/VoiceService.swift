import CueStore
import Foundation
import Observation
import os

/// AppServices 持有唯一通话 owner；页面离开不释放媒体，整个 App 进后台才结束手机媒体。
/// Mac 投影决定业务阶段；本机麦克风、静音确认和电平从不上传，也不据此推断远端正在处理或朗读。
@Observable final class VoiceService {
    @ObservationIgnored unowned let services: AppServices
    @ObservationIgnored let signaling: (any VoiceSignaling)?
    private(set) var projection: VoiceCallProjection?
    var issue: VoiceIssue?
    var availability: VoiceRelayAvailability
    var session: VoiceSessionID?
    var commandResults: [VoiceCommand.ID: VoiceCommandResult.Outcome] = [:]
    @ObservationIgnored var pending: [VoiceCommand.ID: Pending<VoiceCommandResult.Outcome>] = [:]
    @ObservationIgnored var pageReads: [VoiceCommand.ID: Pending<VoicePageResult>] = [:]
    struct Pending<Value: Sendable> {
        let session: VoiceSessionID
        let peer: VoiceEndpoint
        let local: VoiceEndpoint
        let finish: @MainActor @Sendable (Result<Value, Error>) -> Void
    }
    #if os(macOS)
    var call: VoiceCall?
    /// 只登记当前租约的展示接收者，挂断后仍可收更新；不保留服务端页面、游标或业务副本。
    @ObservationIgnored var projectionReaders: [VoiceDeviceID: VoiceSignalHeader] = [:]
    @ObservationIgnored var remote: VoiceRemoteMedia?
    @ObservationIgnored var observing: Task<Void, Never>?
    @ObservationIgnored var commands: [VoiceCommand.ID: Task<VoiceCommandResult.Outcome, Never>] = [:]
    #else
    @ObservationIgnored var phone: VoicePhoneSession?
    @ObservationIgnored var phoneBinding: (session: VoiceSessionID, local: VoiceEndpoint, peer: VoiceEndpoint)?
    let requestPages = VoicePageView<VoiceCallProjection.Request>()
    let replyPages = VoicePageView<VoiceCallProjection.Reply>()
    let executionPages = VoicePageView<VoiceExecutionTarget>()
    var muted = false
    var muting = false
    var closing: Bool { phone?.cleanup != nil }
    var inputSamples: [Double] = []
    var outputSamples: [Double] = []
    var outputActive = false
    #endif

    init(services: AppServices, signaling: (any VoiceSignaling)?) {
        self.services = services
        self.signaling = signaling
        availability = signaling?.voiceAvailability ?? .unsupported
    }

    isolated deinit {
        #if os(macOS)
        observing?.cancel()
        #else
        phone?.scope.end()
        #endif
    }

    func cancel() {
        #if os(macOS)
        observing?.cancel()
        observing = nil
        call?.hangUp()
        #else
        Task { await end(reason: .background) }
        #endif
        failPending { _ in true }
        failPageReads()
        #if os(iOS)
        requestPages.disconnected(clear: false)
        replyPages.disconnected(clear: false)
        executionPages.disconnected(clear: true)
        #endif
    }

    var phase: VoiceCallProjection.Phase? {
        if let issue { return .failed(issue) }
        #if os(iOS)
        if closing { return .closing }
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
        phone?.connected == true && !closing && !muting
        #endif
    }

    var samples: [Double] {
        #if os(macOS)
        call?.samples ?? []
        #else
        outputActive ? outputSamples : (muted ? [] : inputSamples)
        #endif
    }

    var canRepeat: Bool {
        #if os(macOS)
        call?.canRepeat == true && call.map { VoiceSessionID($0.session) } == session
        #else
        phone?.connected == true && !closing && phone?.id == projection?.session && projection?.canRepeat == true
        #endif
    }

    func setProjection(_ value: VoiceCallProjection?) {
        projection = value
        #if os(iOS)
        updatePages(value)
        #endif
    }

    func receive(_ event: VoiceRelayEvent) async {
        switch event {
        case .received(let received):
            if case .pageResult(let result) = received.payload {
                receivePageResult(result, header: received.header)
                return
            }
            if case .pageQuery(let query) = received.payload {
                #if os(macOS)
                receivePageQuery(query, header: received.header)
                #endif
                return
            }
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
            failPending { $0.local == endpoint }
            failPageReads(local: endpoint)
            #if os(macOS)
            projectionReaders = projectionReaders.filter { $0.value.recipient != endpoint }
            #else
            if phoneBinding?.local == endpoint { executionPages.disconnected(clear: true) }
            #endif
            await connectionClosed(local: endpoint, peer: nil, reason: reason)
        case .peerClosed(let endpoint, let departure):
            failPending { $0.peer == endpoint }
            failPageReads(peer: endpoint)
            #if os(macOS)
            projectionReaders = projectionReaders.filter { $0.value.sender != endpoint }
            #else
            if phoneBinding?.peer == endpoint { executionPages.disconnected(clear: true) }
            #endif
            await connectionClosed(local: nil, peer: endpoint, reason: departure == .replaced ? .leaseReplaced : .peerLeft)
        case .rejected(let header, let reason):
            switch header.purpose {
            case .media:
                guard header.session == session else { return }
                await connectionClosed(local: header.sender, peer: header.recipient, reason: .protocolRejected)
            case .command(let id):
                guard let wait = pending[id], wait.session == header.session, wait.local == header.sender, wait.peer == header.recipient else { return }
                pending[id] = nil
                wait.finish(.failure(VoiceSignalError.rejected(reason)))
            case .pageQuery(let id):
                guard let wait = pageReads[id], wait.session == header.session, wait.local == header.sender, wait.peer == header.recipient else { return }
                pageReads[id] = nil
                wait.finish(.failure(VoiceSignalError.rejected(reason)))
            case .commandResult, .pageResult:
                AppServices.log.error("Voice result rejected by Relay: \(reason.rawValue)")
            }
        case .availability(let value):
            availability = value
            #if os(iOS)
            if case .ready = value {} else { executionPages.disconnected(clear: true) }
            #endif
        }
    }

    private func failPending(_ matches: (Pending<VoiceCommandResult.Outcome>) -> Bool) {
        for (id, wait) in pending where matches(wait) {
            pending[id] = nil
            wait.finish(.failure(VoiceSignalError.leaseChanged))
        }
    }
}
