import CueStore
import Foundation

nonisolated enum LiveSignal: Equatable, Codable, Sendable {
    case watch(request: UUID, session: String, open: Bool)
    case pages(request: UUID, session: String, pages: [URL], serving: [URL], sent: Sent?, door: Door?)
    case show(request: UUID, session: String)
    case back(request: UUID, session: String)

    struct Sent: Equatable, Codable, Sendable {
        let url: URL
        let found: Bool
        let at: Date
    }

    struct Door: Equatable, Codable, Sendable {
        let addresses: [LiveTunnel.Address]
        let port: UInt16
        let ticket: Data
        /// 这个会话放行的端口：手机照搬到自己回环上的（`LiveTunnel.Proxy.mirror`）。
        let ports: [Int]

        /// 手机连的是哪个口：只有它变了才重连，放行的端口变了照搬就够（`LiveTunnel.Proxy.mirror`），不断开正看着的页面。
        func sameEntrance(as other: Door?) -> Bool {
            addresses == other?.addresses && port == other?.port && ticket == other?.ticket
        }
    }

    static let renewal = Duration.seconds(10)
    static let lease = Duration.seconds(30)

    var request: UUID {
        switch self {
        case .watch(let request, _, _), .pages(let request, _, _, _, _, _), .show(let request, _), .back(let request, _): request
        }
    }

    var answers: Bool { if case .pages = self { true } else { false } }
}
