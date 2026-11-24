#if os(iOS)
import CueStore
import Foundation
import UIKit

extension Workspace {
    func connectLive(_ preview: LivePreview) async {
        guard let host = preview.host else { return }
        do {
            let link = try LiveLink()
            preview.link = link
            await link.run(preview, host: host, remote: services.liveRemote, previews: livePreviews) { [weak self] in self?.services.liveSignaling?.liveTunnelKey }
            if preview.link === link { preview.link = nil }
        } catch {
            fail(error)
        }
    }

    func keepLivePreviews() {
        let open: Set<UUID> = switch navigation {
        case .wide(let state): Set(state.sessions.map(\.id))
        case .narrow(let state): Set(state.path.compactMap { if case .session(let route) = $0 { route.id } else { nil } })
        }
        livePreviews.keep(open)
    }

    func viewOnMac(_ preview: LivePreview) async {
        guard let host = preview.host else { return }
        await operate(on: host, viewing: preview.sessionID)
    }

    func followReturns() async {
        let activations = NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification)
        await returnFromMac()
        for await _ in activations { await returnFromMac() }
    }

    func returnFromMac() async { await services.liveRemote.comeBack() }
}
#endif
