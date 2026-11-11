import Foundation

/// 项目的工作区（Mac 本机）：项目在这台 Mac 上没绑文件夹时，第一次在这里开工就建 `root/<项目名>` 并绑定（`MacExecutor`），
/// 之后与自己选的文件夹一样（换文件夹照常换）。放在家目录下：访达里看得见，也不在"文稿"里，不被 iCloud 的桌面与文稿同步卷走；
/// 多台 Mac 各有一份，代码靠 git 远端在机器之间走。
/// 根目录默认 `~/CuePad`；环境变量 `CUEPAD_WORKSPACE_DIR`（绝对路径）换掉它，不碰真实世界的进程（装着正式版的 Mac 上的本机构建、截图、测试）
/// 没给时放进隔离库目录，不在真实的家目录下建东西。
public struct Workspaces: Equatable, Sendable {
  public static let environmentKey = "CUEPAD_WORKSPACE_DIR"
  private static let rootName = "CuePad"

  public let root: URL

  public init(root: URL) { self.root = root }

  /// `isolatedLibrary` 是隔离库的目录（不碰真实世界时），碰真实世界为 nil。
  public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment, isolatedLibrary: URL?) -> Workspaces {
    if let override = environment[environmentKey], override.hasPrefix("/") {
      return Workspaces(root: URL(filePath: override, directoryHint: .isDirectory))
    }
    return Workspaces(root: (isolatedLibrary ?? UserHome.directory).appending(path: rootName, directoryHint: .isDirectory))
  }

  public func directory(for projectName: String) -> URL {
    root.appending(path: Self.folderName(for: projectName), directoryHint: .isDirectory)
  }

  /// 工作区的文件夹名：项目名里文件系统不认的字符（`/`、`:`）换成 `-`，开头的点换掉（不然在访达里是隐藏的）。
  public static func folderName(for projectName: String) -> String {
    var name = projectName.trimmingCharacters(in: .whitespacesAndNewlines).replacing(/[\/:]/, with: "-")
    while name.hasPrefix(".") { name = "-" + name.dropFirst() }
    return name.isEmpty ? Project.untitled : name
  }
}
