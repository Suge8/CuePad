import CueText
import Foundation

extension CueStore {
  /// 未删除的项目，按项目唯一的顺序（`projectOrder`）。所有项目列表与选择器都用它，界面不另排。
  public func projects() throws -> [Project] {
    try select(Project.self, where: "deletedAt IS NULL", orderBy: Self.projectOrder("projects"))
  }

  /// 项目的顺序：置顶在前，其余按最近活动——项目自身、其下卡片（灵感与任务）的最近修改中最晚的——由近到远。
  /// Pi 会话的状态变化不算：不然 Agent 一变状态项目就换位置，侧栏在眼前跳、⌘1–9 对应的项目跟着变。`alias` 是查询里项目表的名字。
  static func projectOrder(_ alias: String) -> String {
    """
    \(alias).isPinned DESC, MAX(\(alias).modifiedAt,
      COALESCE((SELECT MAX(modifiedAt) FROM cards WHERE projectID = \(alias).id), 0)) DESC, \(alias).id
    """
  }

  /// 任务（`t`，左连接项目 `p`）按所属项目排：项目顺序同 `projectOrder`。项目还没同步到的任务（引用先于项目送达）
  /// 项目那几个键全是空值，再按 `t.projectID` 排：同一项目的任务总是连在一起，按项目分组时每个项目只成一组。
  static let taskProjectOrder = "\(projectOrder("p")), t.projectID"

  /// 回收站里的条数：删除的项目加单独删除的卡片（`trashedProjects()` 与 `trashedCards()` 的个数之和），只数不读正文。
  public func trashCount() throws -> Int {
    try db.first(
      "SELECT (SELECT COUNT(*) FROM projects WHERE deletedAt IS NOT NULL) + (SELECT COUNT(*) FROM cards WHERE deletedAt IS NOT NULL)"
    ) { Int($0.int(0)) } ?? 0
  }

  /// 回收站里每个项目带进来的卡片数（项目被删后其下的卡片都看不见，含先前单独删除的）：一次查询，没有卡片的项目不在结果里。
  public func trashedProjectCardCounts() throws -> [UUID: Int] {
    Dictionary(uniqueKeysWithValues: try db.query(
      """
      SELECT projectID, COUNT(*) FROM cards
      WHERE NOT (\(Self.cardVisible)) AND projectID IN (SELECT id FROM projects WHERE deletedAt IS NOT NULL) GROUP BY projectID
      """
    ) { ($0.uuid(0), Int($0.int(1))) })
  }

  /// 回收站中的项目，最近删除的在前。
  public func trashedProjects() throws -> [Project] {
    try select(Project.self, where: "deletedAt IS NOT NULL", orderBy: "deletedAt DESC, id")
  }

  public func project(_ id: UUID) throws -> Project? { try find(Project.self, id) }

  /// 工作目录（如 Pi 会话的 cwd）属于哪个项目：两边先换成唯一写法（`canonicalPath`），项目绑定的目录是该目录本身或其祖先，按路径分段比较
  /// （`/a/proj` 不会误配 `/a/project`）；多个命中取绑定目录最深的，同深度取项目列表里靠前的。
  /// 只看未删除的项目，依据本机的目录绑定（`setDirectory`）。界面与命令行共用这唯一一份规则。
  public func project(containing directory: URL) throws -> Project? {
    try Self.projectID(containing: directory, in: boundDirectories()).flatMap { try find(Project.self, $0) }
  }

  /// 项目绑定的目录（已换成唯一写法并按分段拆开），按项目顺序。批量归会话时读一次、对每个会话用 `projectID(containing:in:)`，
  /// 不为每个会话重读绑定表、重做 `realpath`。
  typealias BoundDirectory = (id: UUID, segments: [Substring])

  func boundDirectories() throws -> [BoundDirectory] {
    try db.query(
      """
      SELECT p.id, d.directory FROM projectDirectories d JOIN projects p ON p.id = d.projectID
      WHERE p.deletedAt IS NULL ORDER BY \(Self.projectOrder("p"))
      """
    ) { (id: $0.uuid(0), segments: Self.pathSegments(Self.canonicalPath($0.text(1)))) }
  }

  static func projectID(containing directory: URL, in bound: [BoundDirectory]) -> UUID? {
    let target = pathSegments(canonicalPath(directory.path))
    var best: (id: UUID, depth: Int)?
    for candidate in bound where !candidate.segments.isEmpty && target.starts(with: candidate.segments) {
      if best.map({ candidate.segments.count > $0.depth }) ?? true { best = (candidate.id, candidate.segments.count) }
    }
    return best?.id
  }

  private static func pathSegments(_ path: String) -> [Substring] { path.split(separator: "/") }

  /// 会话记录里的文件夹名（`PiSessionState.folder`）：工作目录的末段；临时目录（/tmp、/var/tmp、/var/folders，含 /private 写法，或路径里有
  /// TemporaryItems）与没有目录的没有。手机看不到路径，只据文件夹名建议绑定，临时目录不该进候选，所以由有路径的 Mac 在写入时认出——规则只此一处。
  public static func folderName(ofWorkingDirectory cwd: String) -> String? {
    guard !cwd.isEmpty, !isTemporary(cwd) else { return nil }
    return URL(filePath: cwd, directoryHint: .isDirectory).lastPathComponent
  }

  private static let temporaryRoots: [[Substring]] = [["tmp"], ["var", "tmp"], ["var", "folders"]]

  private static func isTemporary(_ path: String) -> Bool {
    var segments = pathSegments(URL(filePath: path).standardizedFileURL.path)
    if segments.first == "private" { segments.removeFirst() }
    return segments.contains("TemporaryItems") || temporaryRoots.contains { segments.starts(with: $0) }
  }

  /// 同一个目录的唯一写法：由文件系统解析（`realpath`）——符号链接（含 `/tmp` → `/private/tmp`）换成真实路径，
  /// 大小写换成磁盘上的（区分大小写的卷上写错大小写就是另一个、不存在的目录）。不存在的路径只做标准化。
  static func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return URL(filePath: path).standardizedFileURL.path }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}
