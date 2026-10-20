import Foundation

/// 项目的工作区（Mac 本机）：项目在这台 Mac 上没绑文件夹时，第一次在这里开工就建 `root/<项目名>` 并绑定（`MacExecutor`），
/// 之后与自己选的文件夹一样（换文件夹照常换）。放在家目录下：访达里看得见，也不在"文稿"里，不被 iCloud 的桌面与文稿同步卷走；
/// 多台 Mac 各有一份，代码靠 git 远端在机器之间走。
/// 根目录默认 `~/CuePad`；环境变量 `CUEPAD_WORKSPACE_DIR`（绝对路径）换掉它，隔离运行（开发构建、截图、测试）没给时放进隔离库目录，
/// 不在真实的家目录下建东西。
public struct Workspaces: Equatable, Sendable {
  public static let environmentKey = "CUEPAD_WORKSPACE_DIR"
  /// 根目录的名字：家目录下的 `~/CuePad`，隔离运行时隔离库里的 `CuePad`。
  private static let rootName = "CuePad"

  public let root: URL

  public init(root: URL) { self.root = root }

  /// `isolatedLibrary` 是隔离库的目录（隔离运行时），正式运行为 nil。
  public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment, isolatedLibrary: URL?) -> Workspaces {
    if let override = environment[environmentKey], override.hasPrefix("/") {
      return Workspaces(root: URL(filePath: override, directoryHint: .isDirectory))
    }
    return Workspaces(root: (isolatedLibrary ?? URL.homeDirectory).appending(path: rootName, directoryHint: .isDirectory))
  }

  /// 项目的工作区：根目录下以项目名命名的文件夹（`folderName`）；同名的两个项目共用一个（已存在就直接用）。
  public func directory(for projectName: String) -> URL {
    root.appending(path: Self.folderName(for: projectName), directoryHint: .isDirectory)
  }

  /// 工作区的文件夹名：项目名里文件系统不认的字符（`/`、`:`）换成 `-`，开头的点换掉（不然在访达里是隐藏的）。
  public static func folderName(for projectName: String) -> String {
    var name = projectName.trimmingCharacters(in: .whitespacesAndNewlines).replacing(/[\/:]/, with: "-")
    while name.hasPrefix(".") { name = "-" + name.dropFirst() }
    return name.isEmpty ? Project.untitled : name
  }

  /// 本机路径给人看的写法（Mac 项目页那一行、启用卡里"第一次开工时建好"同一个）：工作区里的从根目录名写起，根在家目录下时带 `~`
  /// （`~/CuePad/默认`，隔离运行是 `CuePad/默认`）；别处家目录下的写成 `~/…`，其余照写全路径。
  public func shown(_ path: String) -> String {
    // 只比路径的各段，不经 standardizedFileURL / resolvingSymlinksInPath：它们对已存在与还没建的目录写法不同（/private/tmp 有时去掉 /private）
    let target = URL(filePath: path).pathComponents, home = URL.homeDirectory.pathComponents, root = root.pathComponents
    let (base, prefix) = target.starts(with: root) ? (Array(root.dropLast()), root.dropLast() == home[...] ? ["~"] : []) : (home, ["~"])
    guard target.count > base.count, target.starts(with: base) else { return path }
    return (prefix + target.dropFirst(base.count)).joined(separator: "/")
  }
}
