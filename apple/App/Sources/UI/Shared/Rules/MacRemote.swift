import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 协议是 UU 官方的 URL Scheme（github.com/netease-uuyc/uuremote-integration-guide，客户端 4.42.0 起）：先绑定——UU 里从用户自己账号下的电脑选一台，
/// 回跳一个加密的设备标识（`DeepLink.remoteBound`）；之后拿标识发起远控。CuePad 的 Mac（`hostID`）对应 UU 里哪台电脑只有用户知道，
/// 所以每台 Mac 第一次连时在 UU 里选一次，标识按 Mac 记在本机偏好（`AppSettings.remoteDevices`），不同步：它绑着这台手机上登录的 UU 账号。
/// 文档说全屏远控成败都不回调（3.3），选错了、换了 UU 账号只能"重新选择 Mac"再绑一次；画中画模式有回调，但每次都要再点小窗才回到全屏、中间还先切回 CuePad，
/// 为拿失败原因让每次连都多两下不值，不用。发远控必须带 `callback`：文档说全屏可省，实测 UU 4.45 不带时只停在设备列表、不连也不报错（2611071115 带上后真机连上）；真回了失败就说原因（`controlFailure`）。
/// 没装 UU 时系统打不开它的链接，这时提示去 App Store 装（文档 1.3）。不先问装没装（`canOpenURL`，iOS 27 起弃用，系统建议直接打开、按结果处理）。
enum MacRemote {
    static let appStore = URL(string: "itms-apps://apps.apple.com/app/id1642306791")!

    static func authorize(nonce: String) -> URL {
        link("authorize", ["callback": DeepLink.remoteCallback.absoluteString, "nonce": nonce])
    }

    /// 回跳带着 `host`：UU 保留回跳原有的参数（文档 3.5），认得出是哪台失败。
    static func control(_ device: String, host: String) -> URL {
        link("control", ["anonymous_device_id": device, "window_type": "0", "callback": DeepLink.remoteControlCallback(host: host).absoluteString])
    }

    /// 参数值除字母数字与 `-._~` 外一律转义（文档 4.5）：设备标识可能带 `+`、`/`、`=`，官方示例的 `.urlQueryAllowed` 与 `appending(queryItems:)`
    /// 都留着原样的 `+`，读的一方按表单规则把它当空格就坏了；转义了两种读法都对。
    private static func link(_ action: String, _ items: KeyValuePairs<String, String>) -> URL {
        var components = URLComponents(string: "uuremote://external/device/\(action)")!
        components.percentEncodedQueryItems = items.map { URLQueryItem(name: $0.key, value: $0.value.addingPercentEncoding(withAllowedCharacters: unreserved)) }
        return components.url!
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// 用户自己取消、被后一次绑定顶掉的不说（文档 2.5 的错误码）。
    static func failure(_ code: String) -> String? {
        switch code {
        case "user_cancel", "superseded": nil
        case "no_device": String(localized: "UU 远程里没有可连的电脑：先在 Mac 上装好 UU 远程并登录同一个账号")
        case "timeout", "not_logined", "logout": String(localized: "UU 远程还没登录好，登录后再试一次")
        default: String(localized: "UU 远程没能选好这台 Mac，再试一次")
        }
    }

    /// 远控失败要告诉用户的话，与要不要给"重新选择 Mac"（文档 3.5 的 reason）：标识失效（换了 UU 账号、解绑）、认不出的失败都请用户重新选；
    /// 用户自己取消的不说，没见过的原因按 connect_failed（文档 3.6）。
    static func controlFailure(_ reason: String) -> (message: String, rebind: Bool)? {
        switch reason {
        case "user_cancel": nil
        case "device_not_found": (String(localized: "UU 远程认不出这台 Mac 了"), true)
        case "busy": (String(localized: "UU 远程正连着别的电脑，先在那边结束再试"), false)
        case "device_offline": (String(localized: "Mac 不在线：唤醒它、开着 UU 远程再试"), false)
        case "not_allowed": (String(localized: "这台 Mac 上的 UU 远程没开允许被控"), false)
        case "network_unavailable": (String(localized: "手机没联网，联网后再试"), false)
        case "login_timeout": (String(localized: "UU 远程还没登录好，登录后再试一次"), false)
        case "connect_timeout": (String(localized: "UU 远程连这台 Mac 超时了，再试一次"), false)
        default: (String(localized: "UU 远程没连上这台 Mac"), true)
        }
    }
}

/// 打开别的 App 的链接，返回打开了没有（没装那个 App 时打不开）：测试换成记下来的替身（只用替身，不真去拉起别的 App）。
struct ExternalApps {
    let open: @MainActor (URL) async -> Bool

    #if canImport(UIKit)
    static let system = ExternalApps { await UIApplication.shared.open($0) }
    #else
    static let system = ExternalApps { _ in false }
    #endif
}
