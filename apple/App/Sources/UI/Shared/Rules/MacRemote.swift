import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 在 Mac 上操作（入口只在手机与 iPad：Cue 页页顶那一排最右的圆钮、会话页"⋯"里）：拉起网易 UU 远程，全屏远程控制一台 Mac。
/// 协议是 UU 官方的 URL Scheme（github.com/netease-uuyc/uuremote-integration-guide，客户端 4.42.0 起）：先绑定——UU 里从用户自己账号下的电脑选一台，
/// 回跳一个加密的设备标识（`DeepLink.remoteBound`）；之后拿标识发起远控。CuePad 的 Mac（`hostID`）对应 UU 里哪台电脑只有用户知道，
/// 所以每台 Mac 第一次连时在 UU 里选一次，标识按 Mac 记在本机偏好（`AppSettings.remoteDevices`），不同步：它绑着这台手机上登录的 UU 账号。
/// 全屏远控成败 UU 都不回调（文档 3.3），选错了、换了 UU 账号只能"重新选择 Mac"再绑一次；画中画模式有回调，但小窗操作不了 Mac，不用。
/// 没装 UU 时系统打不开它的链接，这时提示去 App Store 装（文档 1.3）。不先问装没装（`canOpenURL`，iOS 27 起弃用，系统建议直接打开、按结果处理）。
enum MacRemote {
    static let appStore = URL(string: "itms-apps://apps.apple.com/app/id1642306791")!

    /// 绑定：UU 里选一台电脑，结果接在 `DeepLink.remoteCallback` 后面回跳，`nonce` 原样带回。
    static func authorize(nonce: String) -> URL {
        link("authorize", ["callback": DeepLink.remoteCallback.absoluteString, "nonce": nonce])
    }

    /// 全屏远控已绑定的那台（`window_type=0`）。
    static func control(_ device: String) -> URL {
        link("control", ["anonymous_device_id": device, "window_type": "0"])
    }

    /// 参数值除字母数字与 `-._~` 外一律转义（文档 4.5）：设备标识带 `+`、`/`、`=`，`appending(queryItems:)` 留着原样的 `+`，
    /// UU 读成空格，标识就坏了，全屏远控又不回报，只停在它的设备列表。
    private static func link(_ action: String, _ items: KeyValuePairs<String, String>) -> URL {
        var components = URLComponents(string: "uuremote://external/device/\(action)")!
        components.percentEncodedQueryItems = items.map { URLQueryItem(name: $0.key, value: $0.value.addingPercentEncoding(withAllowedCharacters: unreserved)) }
        return components.url!
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// 绑定失败要告诉用户的话；用户自己取消、被后一次绑定顶掉的不说（文档 2.5 的错误码）。
    static func failure(_ code: String) -> String? {
        switch code {
        case "user_cancel", "superseded": nil
        case "no_device": String(localized: "UU 远程里没有可连的电脑：先在 Mac 上装好 UU 远程并登录同一个账号")
        case "timeout", "not_logined", "logout": String(localized: "UU 远程还没登录好，登录后再试一次")
        default: String(localized: "UU 远程没能选好这台 Mac，再试一次")
        }
    }
}

/// 打开别的 App 的链接，返回打开了没有（没装那个 App 时打不开）：测试换成记下来的替身（只用替身，不真去拉起别的 App）。
struct ExternalApps {
    let open: @MainActor (URL) async -> Bool

    #if canImport(UIKit)
    static let system = ExternalApps { await UIApplication.shared.open($0) }
    #else
    /// Mac 上没有"在 Mac 上操作"的入口。
    static let system = ExternalApps { _ in false }
    #endif
}
