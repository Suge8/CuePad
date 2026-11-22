import Foundation

public enum UserHome {
  public static var directory: URL { URL.homeDirectory }

  public static func expanding(_ path: String) -> String { (path as NSString).expandingTildeInPath }

  public static func shown(_ path: String) -> String {
    // 只比路径的各段，不经 standardizedFileURL / resolvingSymlinksInPath：它们对已存在与还没建的目录写法不同（/private/tmp 有时去掉 /private）
    let target = URL(filePath: path).pathComponents, home = directory.pathComponents
    guard target.count > home.count, target.starts(with: home) else { return NSString.path(withComponents: target) }
    return (["~"] + target.dropFirst(home.count)).joined(separator: "/")
  }
}
