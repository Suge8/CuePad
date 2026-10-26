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

  /// 本进程所属的 App 包：App 与扩展是自己，命令行是外层的那个；不在任何 App 包里为 nil。
  private static let bundle: Bundle? = {
    if Bundle.main.object(forInfoDictionaryKey: infoKey) != nil { return .main }
    let helpers = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
    guard let helpers, helpers.lastPathComponent == "Helpers",
      let app = Bundle(url: helpers.deletingLastPathComponent().deletingLastPathComponent()),
      app.object(forInfoDictionaryKey: infoKey) != nil
    else { return nil }
    return app
  }()

  public static let id: String = bundle?.object(forInfoDictionaryKey: infoKey) as? String ?? unbundled

  public static var appGroup: String { "group.\(id)" }
  public static var iCloudContainer: String { "iCloud.\(id)" }

  #if os(macOS)
  /// 本进程是不是正式版（Mac 上只有它开真实资料库、带自动更新，见 `LibraryLocation`）：发版脚本归档时把 `Signing.xcconfig` 的
  /// `CUEPAD_RELEASE` 设成 YES，经 Info.plist 的 `CuePadRelease` 带进包里；本机、测量（perf 的 Release）与测试构建都是 NO。
  /// 构建时定下、读一个键：不在启动的主线程上读签名（`SecCode` 读签名信息要几到几十毫秒，系统还为此报一条性能 fault）。
  public static let isRelease = bundle.map(isRelease(_:)) ?? false

  /// 这个 App 包是不是正式版：同上，看别的副本（`touchesRealWorld` 找这台装没装正式版）。
  public static func isRelease(at app: URL) -> Bool { Bundle(url: app).map(isRelease(_:)) ?? false }

  private static func isRelease(_ bundle: Bundle) -> Bool { bundle.object(forInfoDictionaryKey: "CuePadRelease") as? String == "YES" }
  #endif
}

extension Logger {
  /// 停摆的现场（notice 级别落盘，docs/sync.md「拉取节奏与门铃」）：Mac 等着拉时的晚醒与排队（`AppServices.holdActivityWhilePolling`）、
  /// 一拉太久与拉取节奏迟醒（`SyncPoller`）都记在这一类里。
  public static let stall = Logger(subsystem: AppIdentity.id, category: "stall")
}
