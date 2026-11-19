import Foundation

/// 手机、iPad 看 Mac 会话的活预览：手机问、Mac 答，走通话那条端到端加密的信令（`VoiceSignalPayload.live`），中转只转不看。
/// 手机只在会话页看得见、那台 Mac 在线时问（`LiveRemote`）；Mac 只答自己这台上的会话（`Workspace.receiveLive`）。
nonisolated enum LiveSignal: Equatable, Codable, Sendable {
    /// 手机：这个会话页我正开着；`open` 是它的活预览也开着，要隧道的入口。每 `renewal` 重发一次，Mac 过了 `lease` 没再收到就当他走了。
    case watch(request: UUID, session: String, open: Bool)
    /// Mac：这个会话此刻可看的页面，点开时开的在前，没有是空的；其中认出在服务的（`serving`）；开着预览时的入口。有变化 Mac 主动再答一次。
    case pages(request: UUID, session: String, pages: [URL], serving: [URL], door: Door?)

    /// 去 Mac 的隧道（`LiveTunnel`）：Mac 在局域网上的地址、此刻的端口，与一张只给这台手机、这个会话的票据。
    struct Door: Equatable, Codable, Sendable {
        let addresses: [LiveTunnel.Address]
        let port: UInt16
        let ticket: Data
    }

    static let renewal = Duration.seconds(10)
    static let lease = Duration.seconds(30)

    var request: UUID {
        switch self {
        case .watch(let request, _, _), .pages(let request, _, _, _, _): request
        }
    }

    var answers: Bool { if case .pages = self { true } else { false } }
}
