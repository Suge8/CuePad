import CloudKit
import CueSync
import Foundation
#if os(iOS)
import UIKit
#endif

extension AppServices {
    static func makeRelay(_ source: SyncSource, _ sync: (any SyncControlling)?, device: String?) -> Relay? {
        let endpoint: URL
        switch source {
        case .iCloud where !DebugHooks.relayOff: endpoint = URL(string: "wss://\(relayHost)/v1")!
        case .built(_, let relay?): endpoint = relay
        default: return nil
        }
        guard let sync = sync as? CloudSync, let device else { return nil }
        return Relay(endpoint: endpoint, device: device) { try RelayCredentials(secret: try await sync.relaySecret()) }
    }

    func startRelay() {
        guard let relay, let sync = sync as? CloudSync else { return }
        let voiceEvents = relay.voiceEvents
        follow {
            for await event in voiceEvents {
                if case .received(let signal) = event, case .live = signal.payload {
                    self.liveEvents.continuation.yield(event)
                    continue
                }
                if case .received = event {} else { self.liveEvents.continuation.yield(event) }
                await self.voice.receive(event)
            }
        }
        let accepted = sync.acceptedUpdates, accountChanged = NotificationCenter.default.notifications(named: .CKAccountChanged)
        follow {
            for await _ in accepted { relay.ring() }
        }
        follow {
            for await _ in accountChanged { await relay.reconnect() }
        }
        #if os(iOS)
        let liveEvents = liveEvents.stream
        follow { for await event in liveEvents { self.liveRemote.receive(event) } }
        #endif
        #if os(macOS)
        follow { await relay.run(connected: true) { await self.syncing.pull() } }
        #else
        follow { await relay.run(connected: UIApplication.shared.applicationState != .background) { await self.syncing.pull() } }
        #endif
    }

    var doorbellFallback: Duration? { relay?.isLive == true ? Relay.silenceLimit : nil }

    static var relayHost: String {
        guard let host = Bundle.main.object(forInfoDictionaryKey: "CuePadRelayHost") as? String, !host.isEmpty else {
            preconditionFailure("Info.plist 缺 CuePadRelayHost（Signing.xcconfig 的 CUEPAD_RELAY_HOST）")
        }
        return host
    }
}
