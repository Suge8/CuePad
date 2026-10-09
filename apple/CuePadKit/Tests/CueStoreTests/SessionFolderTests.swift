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
}
