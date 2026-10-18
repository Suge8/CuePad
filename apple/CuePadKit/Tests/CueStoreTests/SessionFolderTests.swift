import CueStore
import Foundation
import Testing

/// 会话归哪个项目写在记录上（写入时按本机的目录绑定定）：绑定或解除时本机已有的会话（含几千条历史）要跟着归进来、放出去；
/// 手机据"各 Mac 上跑过 Agent 的文件夹"建议绑定（`sessionFolders`）。
@Suite struct SessionFolderTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }

  private func index(_ id: String, cwd: String) async throws {
    try await store.upsertPiSession(IndexedSession(id: id, path: "/s/\(id).jsonl", cwd: cwd, lastActivityAt: Date()), host: "mac-a")
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

  @Test func sessionFoldersAreGroupedPerMacAndFolderWithCountAndTheLatestSession() async throws {
    let project = try await store.createProject(name: "App", color: "#111")
    let base = Date(timeIntervalSince1970: 1_000_000)
    func write(_ id: String, folder: String?, host: String, at offset: TimeInterval, project: UUID? = nil) async throws {
      try await PiStateRecorder(store: store, hostID: host).update(
        sessionID: id, state: .settled, title: id, directory: folder, projectID: project,
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

  /// 只看几个名字的订阅（项目引导的同名建议）只依赖那些文件夹里的会话：别的会话怎么变它都不重读，但它依赖的那些
  /// 一变（新会话、最近的换了、会话不在那个文件夹了）就照常更新。名字不分大小写，非 ASCII 的大小写也认。
  @Test(.timeLimit(.minutes(1))) func foldersNamedFollowOnlyTheirOwnSessions() async throws {
    let base = Date(timeIntervalSince1970: 1_000_000)
    func write(_ id: String, folder: String, at offset: TimeInterval) async throws {
      try await PiStateRecorder(store: store, hostID: "mac-a").update(
        sessionID: id, state: .settled, title: id, directory: "/work/\(folder)",
        times: PiTimes(stateSince: base.addingTimeInterval(offset), busySince: nil))
    }
    try await write("a1", folder: "App", at: 10)
    try await write("x1", folder: "site", at: 20)
    var values = store.observe { try $0.sessionFolders(named: ["app", "éclair"]).map { "\($0.folder):\($0.sessionID):\($0.count)" } }
      .makeAsyncIterator()
    #expect(try await values.next() == ["App:a1:1"])

    try await write("x1", folder: "site", at: 30)  // 别的文件夹里的会话变了：结果不变
    try await write("a2", folder: "app", at: 40)  // 同名（大小写不同）的新文件夹
    #expect(try await values.next() == ["app:a2:1", "App:a1:1"])
    try await write("a1", folder: "App", at: 50)  // 依赖的会话成了最近的
    #expect(try await values.next() == ["App:a1:1", "app:a2:1"])
    try await write("a1", folder: "site", at: 60)  // 依赖的会话离开了那个文件夹
    #expect(try await values.next() == ["app:a2:1"])
    try await write("e1", folder: "Éclair", at: 70)
    #expect(try await values.next() == ["Éclair:e1:1", "app:a2:1"])
  }
}
