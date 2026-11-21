import CueText
import Foundation

extension CueStore {
  public func projects() throws -> [Project] {
    try select(Project.self, where: "deletedAt IS NULL", orderBy: Self.projectOrder("projects"))
  }

  static func projectOrder(_ alias: String) -> String {
    """
    \(alias).isPinned DESC, MAX(\(alias).createdAt,
      COALESCE((SELECT MAX(\(cardProgress)) FROM cards WHERE projectID = \(alias).id), 0),
      COALESCE((SELECT MAX(\(turnProgress)) FROM piSessionStates WHERE projectID = \(alias).id), 0)) DESC, \(alias).id
    """
  }

  /// 灵感没有单独的编辑时刻，取回、恢复那一下会算成修改。索引与查询同出这一句（不一样就用不上）。
  static let cardProgress = """
    CASE WHEN todoAt IS NULL THEN CASE WHEN deletedAt IS NULL AND archivedAt IS NULL THEN modifiedAt END \
    ELSE max(todoAt, COALESCE(startedAt, 0), COALESCE(completedAt, 0)) END
    """

  static let turnProgress = "max(COALESCE(turnStartedAt, 0), COALESCE(answeredAt, 0))"

  static let taskProjectOrder = "\(projectOrder("p")), t.projectID"

  public func trashedProjectCardCounts() throws -> [UUID: Int] {
    Dictionary(uniqueKeysWithValues: try db.query(
      """
      SELECT projectID, COUNT(*) FROM cards
      WHERE NOT (\(Self.cardVisible)) AND projectID IN (SELECT id FROM projects WHERE deletedAt IS NOT NULL) GROUP BY projectID
      """
    ) { ($0.uuid(0), Int($0.int(1))) })
  }

  public func trashedProjects() throws -> [Project] {
    try select(Project.self, where: "deletedAt IS NOT NULL", orderBy: "deletedAt DESC, id")
  }

  public func project(_ id: UUID) throws -> Project? { try find(Project.self, id) }

  public func project(containing directory: URL) throws -> Project? {
    try Self.projectID(containing: directory, in: boundDirectories()).flatMap { try find(Project.self, $0) }
  }

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
