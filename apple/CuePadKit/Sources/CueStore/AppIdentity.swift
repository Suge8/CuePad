import Foundation

/// App 的身份前缀：主 App 的 bundle id、偏好域、日志 subsystem 就是它，App Group 与 iCloud 容器由它派生。
/// 唯一定义是 `App/Config/Signing.xcconfig` 的 `CUEPAD_APP_ID`，经构建设置展开进 App 与各扩展 Info.plist 的 `CuePadAppID`，运行期只读这个键。
/// 随 App 分发的命令行在 `<App>.app/Contents/Helpers/` 里，`Bundle.main` 认不出外层的包，从那里读。
/// 不在任何 App 包里的进程（Kit 的测试、自己编的命令行）没有身份，用 `unbundled`：只和同样不在包里的进程互通，不冒充哪个 App。
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
