import CloudKit
import CueStore
import CueSync
import Foundation
#if os(iOS)
import UIKit
#endif

/// 实时层接入：本机的一批改动被 iCloud 收下就按门铃，听到门铃就拉一次（`pull`，与按节奏的拉取同一拉）。
/// 何时连着：Mac 只要 App 在跑（Mac 不收推送，不在等时别的设备的改动原本要等下一次被叫醒才拉）；手机在前台时，
/// 进后台由 `prepareForBackground` 在本机改动传完、门铃按完后断开（`Relay.pause`、`settle`），回前台再连；换了 iCloud 账号就换房间重连。
/// 门铃随时可能响：`pull` 合并同一时刻的拉取，同步还在启动时先等启动，所以与按节奏的拉取、立即同步、冷启动的第一拉不冲突。
/// 只在真连着 iCloud（与 `makeSync` 选 `.iCloud` 同一组条件）、构建配了中转（`relayHost`）时启用；没配的（自己编译没架中转）照常按节奏拉。
extension AppServices {
    func startRelay() {
        guard let sync, sync is CloudSync, Entitlements.hasCloudKit, !location.isIsolated || DebugHooks.syncsIsolatedLibrary,
            let host = Self.relayHost
        else { return }
        let database = CKContainer(identifier: AppIdentity.iCloudContainer).privateCloudDatabase
        let relay = Relay(host: host) { try await RelayKey.credentials(in: database) }
        self.relay = relay
        follow {
            for await _ in sync.acceptedUpdates { relay.ring() }
        }
        follow {
            for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) { await relay.reconnect() }
        }
        #if os(macOS)
        follow { await relay.run(connected: true) { await self.pull() } }
        #else
        follow { await relay.run(connected: UIApplication.shared.applicationState != .background) { await self.pull() } }
        follow {
            for await _ in NotificationCenter.default.notifications(named: UIApplication.willEnterForegroundNotification) { relay.resume() }
        }
        #endif
    }

    /// 门铃此刻通着：别的设备的改动一被收下这台就会来拉，按节奏的拉取降为兜底（`pollingCadence`）。
    var doorbellLive: Bool { relay?.isLive == true }

    /// 中转的主机（可带端口）：构建设置 `CUEPAD_RELAY_HOST` 经 Info.plist 的 `CuePadRelayHost` 给出，空的就是没有中转。
    static var relayHost: String? {
        let host = DebugHooks.relayHost ?? Bundle.main.object(forInfoDictionaryKey: "CuePadRelayHost") as? String
        return host?.isEmpty == false ? host : nil
    }
}
