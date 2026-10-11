import CueStore
import Foundation
import Testing

/// 会话工作目录属于哪个项目：项目绑定的目录是该目录本身或其祖先，按路径分段比较（`/a/proj` 不误配 `/a/project`），
/// 多个命中取绑定目录最深的；只看未删除的项目。
@Suite struct ProjectMatchTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private struct World {
    let proj: Project, outer: Project, project: Project
  }

  private func world() async throws -> World {
    let proj = try await store.createProject(name: "proj", color: "#111")
    let outer = try await store.createProject(name: "outer", color: "#222")
    let project = try await store.createProject(name: "project", color: "#333")
    try await store.setDirectory("/a/proj", for: proj.id)
    try await store.setDirectory("/a", for: outer.id)
    try await store.setDirectory("/a/project/", for: project.id)  // 末尾斜杠不影响
    return World(proj: proj, outer: outer, project: project)
  }

  private func match(_ path: String) async throws -> String? {
    try await store.project(containing: URL(filePath: path))?.name
  }

  @Test(arguments: [
    ("/a/proj", "proj"),
    ("/a/proj/src/ui", "proj"),
    ("/a/project", "project"),
    ("/a/project/x", "project"),
    ("/a/other", "outer"),
    ("/a/proj/../project/x", "project"),  // 先规整路径再比较
  ])
  func matchesByPathSegmentsAndPrefersTheDeepestBinding(path: String, expected: String) async throws {
    _ = try await world()
    #expect(try await match(path) == expected)
  }

  @Test func directoriesOutsideEveryBindingMatchNothing() async throws {
    _ = try await world()
    #expect(try await match("/b/proj") == nil)
    #expect(try await match("/") == nil)
  }

  @Test func trashedProjectsAreSkippedAndComeBackOnRestore() async throws {
    let w = try await world()
    try await store.trashProject(w.proj.id)
    #expect(try await match("/a/proj/src") == "outer")  // 退到更浅的祖先绑定

    try await store.trashProject(w.outer.id)
    #expect(try await match("/a/proj/src") == nil)

    try await store.restoreProject(w.proj.id)
    #expect(try await match("/a/proj/src") == "proj")
  }

  @Test func unboundProjectsNeverMatchAndUnbindingStopsMatching() async throws {
    let w = try await world()
    _ = try await store.createProject(name: "no directory", color: "#444")
    #expect(try await match("/elsewhere") == nil)

    try await store.setDirectory(nil, for: w.proj.id)
    #expect(try await match("/a/proj/x") == "outer")
  }

  @Test func projectsBoundToTheSameDirectoryResolveByProjectOrder() async throws {
    let first = try await store.createProject(name: "first", color: "#111")
    let second = try await store.createProject(name: "second", color: "#222")
    try await store.updateProject(first.id) { $0.isPinned = true }
    try await store.setDirectory("/shared", for: second.id)
    try await store.setDirectory("/shared", for: first.id)
    #expect(try await match("/shared/x") == "first")  // 项目列表里靠前的
  }

  // MARK: 同一个目录的不同写法

  /// 磁盘上真实存在的一棵目录：`Repo/Sub`，旁边一个指向 `Repo` 的符号链接 `link`。
  private func disk() throws -> (repo: URL, link: URL) {
    let root = fixture.directory.appending(path: "disk", directoryHint: .isDirectory)
    let repo = root.appending(path: "Repo", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: repo.appending(path: "Sub"), withIntermediateDirectories: true)
    let link = root.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo)
    return (repo, link)
  }

  @Test func aSymlinkOnEitherSideStillMatches() async throws {
    let (repo, link) = try disk()
    let viaLink = try await store.createProject(name: "经链接绑定", color: "#111")
    try await store.setDirectory(link.path, for: viaLink.id)
    #expect(try await match(repo.appending(path: "Sub").path) == "经链接绑定")

    try await store.setDirectory(repo.path, for: viaLink.id)
    #expect(try await match(link.appending(path: "Sub").path) == "经链接绑定")
  }

  #if os(macOS)
  /// 不区分大小写的卷（macOS 默认）上，大小写不同的写法是同一个目录。绑定的目录只在 Mac 上用；iOS 模拟器的 realpath 不修大小写，规则不适用。
  @Test(.enabled(if: caseInsensitiveTemporaryVolume)) func aDifferentlyCasedPathMatchesOnACaseInsensitiveVolume() async throws {
    let (repo, _) = try disk()
    let project = try await store.createProject(name: "小写绑定", color: "#111")
    try await store.setDirectory(repo.deletingLastPathComponent().appending(path: "repo").path, for: project.id)
    #expect(try await match(repo.appending(path: "Sub").path) == "小写绑定")
  }
  #endif
}

#if os(macOS)
private let caseInsensitiveTemporaryVolume =
  (try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
    .volumeSupportsCaseSensitiveNames == false
#endif
