import Foundation
import os

/// App 的身份前缀：主 App 的 bundle id、偏好域、日志 subsystem 就是它，App Group 与 iCloud 容器由它派生。
/// 唯一定义是 `App/Config/Signing.xcconfig` 的 `CUEPAD_APP_ID`，经构建设置展开进 App 与各扩展 Info.plist 的 `CuePadAppID`，运行期只读这个键。
/// 随 App 分发的命令行在 `<App>.app/Contents/Helpers/` 里，`Bundle.main` 认不出外层的包，从那里读。
/// 不在任何 App 包里的进程（Kit 的测试、自己编的命令行）没有身份，用 `unbundled`，不冒充哪个 App；
/// Mac 上库变更通知用不随身份的固定前缀（`ChangeNotification`），它们开同一个开发库时照样和开发版 App 互通。
public enum AppIdentity {
  static let infoKey = "CuePadAppID"
  static let unbundled = "cuepad.unbundled"

  public static let id: String = {
    if let id = Bundle.main.object(forInfoDictionaryKey: infoKey) as? String { return id }
    let helpers = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
    if let helpers, helpers.lastPathComponent == "Helpers",
      let app = Bundle(url: helpers.deletingLastPathComponent().deletingLastPathComponent()),
      let id = app.object(forInfoDictionaryKey: infoKey) as? String
    {
      return id
    }
    return unbundled
  }()

  public static var appGroup: String { "group.\(id)" }
  public static var iCloudContainer: String { "iCloud.\(id)" }
}

extension Logger {
  /// 停摆的现场（notice 级别落盘，docs/sync.md「拉取节奏」）：Mac 等着拉时的晚醒与排队（`AppServices.holdActivityWhilePolling`）、
  /// 一拉太久与拉取节奏迟醒（`SyncPoller`）都记在这一类里。
  public static let stall = Logger(subsystem: AppIdentity.id, category: "stall")
}
