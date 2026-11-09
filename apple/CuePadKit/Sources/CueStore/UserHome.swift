import Foundation

/// 当前用户真实的家目录：进程里只经这里取（`lint.sh` 拦别的写法）。读写各家 Agent 的东西走 `AgentPaths`，它认环境里给的 HOME，
/// 隔离实例与测试经它换到临时目录；这里只给确实要真实那个的：给人看的 `~/…`、展开用户写的 `~`、各家缺省位置的兜底。
public enum UserHome {
  public static var directory: URL { URL.homeDirectory }

  /// `~`、`~/…` 展开成家目录下的路径，别的原样。
  public static func expanding(_ path: String) -> String { (path as NSString).expandingTildeInPath }

  /// 给人看的写法（Mac 上项目的文件夹在哪，`ProjectPlace`；接入面板里任务在哪做同一个）：家目录下的写成 `~/…`（`~/CuePad/默认`），其余照写全路径。
  public static func shown(_ path: String) -> String {
    // 只比路径的各段，不经 standardizedFileURL / resolvingSymlinksInPath：它们对已存在与还没建的目录写法不同（/private/tmp 有时去掉 /private）
    let target = URL(filePath: path).pathComponents, home = directory.pathComponents
    guard target.count > home.count, target.starts(with: home) else { return NSString.path(withComponents: target) }
    return (["~"] + target.dropFirst(home.count)).joined(separator: "/")
  }
}
