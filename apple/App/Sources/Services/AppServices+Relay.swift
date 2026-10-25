import CloudKit
import CueSync
import Foundation
#if os(iOS)
import UIKit
#endif

/// 实时层接入：本机的一批改动被 iCloud 收下就按门铃，听到门铃就拉一次（`pull`，与按节奏的拉取同一拉）。
/// 何时连着：Mac 只要 App 在跑（Mac 不收推送，不在等时别的设备的改动原本要等下一次被叫醒才拉）；手机在前台时，
/// App 整个进后台由 `prepareForBackground` 在本机改动传完、门铃按完后断开（`Relay.pause`、`settle`），回前台经 `handleActivation` 再连；
/// 换了 iCloud 账号就换房间重连。门铃随时可能响：`pull` 合并同一时刻的拉取，同步还在启动时先等启动，所以与按节奏的拉取、立即同步、冷启动的第一拉不冲突。
/// 只在真连着 iCloud（`makeSync` 建了 `CloudSync`）、构建配了中转（`relayHost`）时有；没配的（自己编译没架中转）照常按节奏拉。
extension AppServices {
    static func makeRelay(_ sync: (any SyncControlling)?) -> Relay? {
        guard let sync = sync as? CloudSync, let host = relayHost else { return nil }
        return Relay(host: host) { try RelayCredentials(secret: try await sync.relaySecret()) }
    }

    func startRelay() {
        guard let relay, let sync = sync as? CloudSync else { return }
        let accepted = sync.acceptedUpdates  // 当场订阅：同步一启动就可能有一批被收下，那时跟随者还没跑起来
        follow {
            for await _ in accepted { relay.ring() }
        }
        follow {
            for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) { await relay.reconnect() }
        }
        #if os(macOS)
        follow { await relay.run(connected: true) { await self.pull() } }
        #else
        follow { await relay.run(connected: UIApplication.shared.applicationState != .background) { await self.pull() } }
        #endif
    }

    /// 门铃通着时按节奏的拉取降到的兜底间隔（`pollingCadence`）；nil 是门铃不通。
    var doorbellFallback: Duration? { relay?.isLive == true ? Relay.silenceLimit : nil }

    /// 中转的主机（可带端口）：构建设置 `CUEPAD_RELAY_HOST` 经 Info.plist 的 `CuePadRelayHost` 给出，空的就是没有中转。
    static var relayHost: String? {
        let host = DebugHooks.relayHost ?? Bundle.main.object(forInfoDictionaryKey: "CuePadRelayHost") as? String
        return host?.isEmpty == false ? host : nil
    }
}
