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
/// 只在真连着 iCloud（同步来源是 `.iCloud`、`makeSync` 建了 `CloudSync`）时有：测试与调试画面的替身云（`.built`、`.custom`）不连中转。
/// 同步测量的隔离实例连的是 CloudKit 开发环境，密钥（`CloudSync.relaySecret`）从开发容器取，派生的房间与正式用户的不会重合。
extension AppServices {
    static func makeRelay(_ source: SyncSource, _ sync: (any SyncControlling)?) -> Relay? {
        guard case .iCloud = source, let sync = sync as? CloudSync else { return nil }
        return Relay(host: relayHost) { try RelayCredentials(secret: try await sync.relaySecret()) }
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

    /// 中转的主机：唯一定义是 `Signing.xcconfig` 的 `CUEPAD_RELAY_HOST`，经 Info.plist 的 `CuePadRelayHost` 给 App（发布脚本核对过它在包里）。
    static var relayHost: String {
        guard let host = Bundle.main.object(forInfoDictionaryKey: "CuePadRelayHost") as? String, !host.isEmpty else {
            preconditionFailure("Info.plist 缺 CuePadRelayHost（Signing.xcconfig 的 CUEPAD_RELAY_HOST）")
        }
        return host
    }
}
