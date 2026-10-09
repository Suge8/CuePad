import CueStore
import Foundation
import Testing

/// 会话归哪个项目写在记录上（写入时按本机的目录绑定定）：绑定或解除时本机已有的会话（含几千条历史）要跟着归进来、放出去；
/// 手机据"各 Mac 上跑过 Agent 的文件夹"建议绑定（`sessionFolders`）。
@Suite struct SessionFolderTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private func index(_ id: String, cwd: String) async throws {
    try await store.upsertPiSession(PiSession(id: id, path: "/s/\(id).jsonl", cwd: cwd, lastActivityAt: Date()), host: "mac-a")
  }

  private func projects() async throws -> [String: UUID?] {
    Dictionary(uniqueKeysWithValues: try await store.allPiSessionStates().map { ($0.sessionID, $0.projectID) })
  }

  @Test func bindingAFolderPutsExistingSessionsIntoTheProjectAndUnbindingTakesThemOut() async throws {
    try await index("in-folder", cwd: "/work/app")
    try await index("in-subfolder", cwd: "/work/app/packages/ui")
    try await index("elsewhere", cwd: "/work/other")
    try await index("near-miss", cwd: "/work/application")
    let project = try await store.createProject(name: "App", color: "#111")
    #expect(try await projects().values.allSatisfy { $0 == nil })

    try await store.setDirectory("/work/app", for: project.id)
    let bound = try await projects()
    #expect(bound["in-folder"] == project.id && bound["in-subfolder"] == project.id)
    #expect(bound["elsewhere"] == .some(nil) && bound["near-miss"] == .some(nil))  // 按路径分段比，application 不算 app 里的

    try await store.setDirectory("/work/other", for: project.id)  // 改绑：旧的放出去，新的归进来
    let moved = try await projects()
    #expect(moved["elsewhere"] == project.id && moved["in-folder"] == .some(nil) && moved["in-subfolder"] == .some(nil))

    try await store.setDirectory(nil, for: project.id)
    #expect(try await projects().values.allSatisfy { $0 == nil })
  }

  @Test func reassigningTouchesOnlyTheSessionsWhoseProjectChanged() async throws {
    try await index("a", cwd: "/work/app")
    try await index("b", cwd: "/work/other")
    let before = try await store.allPiSessionStates().first { $0.sessionID == "b" }?.modifiedAt
    let project = try await store.createProject(name: "App", color: "#111")

    try await store.setDirectory("/work/app", for: project.id)

    #expect(try await store.allPiSessionStates().first { $0.sessionID == "b" }?.modifiedAt == before)  // 没变的不重写，免得白白重传
  }

  @Test func sessionFoldersAreGroupedPerMacAndFolderWithCountAndTheLatestSession() async throws {
    let project = try await store.createProject(name: "App", color: "#111")
    let base = Date(timeIntervalSince1970: 1_000_000)
    func write(_ id: String, folder: String?, host: String, at offset: TimeInterval, project: UUID? = nil) async throws {
      try await PiStateRecorder(store: store, hostID: host).update(
        sessionID: id, state: .settled, title: id, folder: folder, projectID: project,
        times: PiTimes(stateSince: base.addingTimeInterval(offset), busySince: nil))
    }
    try await write("old", folder: "app", host: "mac-a", at: 10)
    try await write("new", folder: "app", host: "mac-a", at: 30, project: project.id)
    try await write("mid", folder: "app", host: "mac-a", at: 20)
    try await write("site", folder: "site", host: "mac-a", at: 25)
    try await write("other-mac", folder: "app", host: "mac-b", at: 5)
    try await write("no-folder", folder: nil, host: "mac-a", at: 50)

    let folders = try await store.sessionFolders()

    #expect(folders.map { "\($0.hostID)/\($0.folder)" } == ["mac-a/app", "mac-a/site", "mac-b/app"])  // 最近的在前
    #expect(folders.map(\.count) == [3, 1, 1])
    #expect(folders[0].sessionID == "new" && folders[0].projectID == project.id)  // 代表会话是最近那个
    #expect(folders[2].sessionID == "other-mac" && folders[2].projectID == nil)
  }

  /// 临时目录（/tmp、/var/folders、TemporaryItems 一类）没有文件夹名：手机看不到路径、只据文件夹名建议绑定，临时目录不该进候选，
  /// 所以由有路径的 Mac 在写入时认出（规则只此一处）。
  @Test(arguments: [
    ("/tmp/work", nil), ("/private/tmp/prewalk/repo", nil), ("/var/tmp/y", nil),
    ("/var/folders/73/5xrv72hn/T/pi-2860-1778088354847-jbv635t4er", nil), ("/private/var/folders/73/5xrv72hn/T/prewalk/repo", nil),
    ("/Users/me/Library/Caches/TemporaryItems/NSIRD_x", nil), ("", nil),
    ("/Users/me/Project/Taber", "Taber"), ("/Users/me/tmp/project", "project"), ("/Users/me/tmp-notes", "tmp-notes"), ("/opt/tmp", "tmp"),
  ] as [(String, String?)])
  func temporaryDirectoriesHaveNoFolderName(cwd: String, name: String?) {
    #expect(CueStore.folderName(ofWorkingDirectory: cwd) == name)
  }

  @Test func temporarySessionsAreNeverFolderCandidatesAndLegacyRecordsAreCleanedOnBackfill() async throws {
    try await index("kept", cwd: "/work/app")
    try await index("temp", cwd: "/private/tmp/scratch")
    #expect(try await store.allPiSessionStates().first { $0.sessionID == "temp" }?.folder == nil)
    #expect(try await store.allPiSessionStates().first { $0.sessionID == "temp" }?.title == "scratch")  // 没有文件夹名也不丢显示名

    // 旧版本写下的记录带着临时目录的文件夹名：回填时清掉
    try RawDB(fixture.url).exec("UPDATE piSessions SET cwd = '/var/folders/73/x/T/pi-1' WHERE id = 'kept'; UPDATE piSessionStates SET folder = 'pi-1' WHERE sessionID = 'kept'")
    try await store.retainPiSessions(paths: ["/s/kept.jsonl", "/s/temp.jsonl"], host: "mac-a")

    #expect(try await store.sessionFolders().isEmpty)
  }

  @Test func foldersWithTheSameLatestTimeListTheOneWithMoreSessionsFirst() async throws {
    let at = Date(timeIntervalSince1970: 1_000_000)
    for (id, folder) in [("a1", "few"), ("b1", "many"), ("b2", "many"), ("b3", "many")] {
      try await PiStateRecorder(store: store, hostID: "mac-a").update(
        sessionID: id, state: .settled, title: id, folder: folder, times: PiTimes(stateSince: at, busySince: nil))
    }

    #expect(try await store.sessionFolders().map(\.folder) == ["many", "few"])
  }
}
