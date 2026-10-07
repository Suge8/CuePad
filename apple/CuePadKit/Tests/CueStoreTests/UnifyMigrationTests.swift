import CueStore
import CueTestSupport
import Foundation
import Testing

/// 真实旧库（结构版本 12，由合并前的版本写出：项目带目标卡、三级任务、带任务的发送记录与投送请求、已同步过的任务）升级：
/// 任务原样变成要做的卡片（id 不变，状态、上级、会话、排序照搬），发送记录与投送请求指向同一张卡，
/// 目标卡第一行（去掉"目标："）填进项目介绍、目标卡变回普通灵感，tasks 表与它的同步元数据去掉。
@Suite struct UnifyMigrationTests {
  private static let ids = (
    project: UUID(uuidString: "F98C7363-E9A0-4A95-9974-6CBD9F39CB9B")!, goal: UUID(uuidString: "548C9C32-6F6F-4B69-B768-F7FE2556F382")!,
    note: UUID(uuidString: "D84CF3EC-C728-4590-A55D-28E8CC11A1BB")!, top: UUID(uuidString: "2DB1885D-588B-4870-AA18-239681FDF91C")!,
    sub: UUID(uuidString: "9BC928A5-DA1D-46F1-8797-5A76AAFEFB3B")!, leaf: UUID(uuidString: "DB18792B-4414-4593-82AB-85748CB2CC0D")!,
    loose: UUID(uuidString: "8B4DF51B-0BD4-479E-BA46-3D957E30FB39")!)

  private func upgraded() throws -> (CueStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "unify-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "cuepad.db")
    let fixture = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/library-v12.sqlite")
    try FileManager.default.copyItem(at: fixture, to: url)
    return (try CueStore(url: url), url)
  }

  @Test func 任务变成要做的卡片_状态上级会话照搬() async throws {
    let (store, _) = try upgraded()
    let ids = Self.ids
    let top = try #require(try await store.card(ids.top))
    #expect(top.isTask && top.body == "修 scheduler 重连排序" && top.projectID == ids.project)
    #expect(top.status == .inProgress && top.piSessionID == "s1")
    #expect(try await store.card(ids.sub)?.parentID == ids.top)
    #expect(try await store.card(ids.leaf)?.status == .done)
    #expect(try await store.card(ids.loose)?.status == .inProgress)
    #expect(try await store.taskCounts()[ids.project] == TaskCounts(inProgress: 1, todo: 0, done: 0))
  }

  @Test func 发送记录与投送请求指向同一张卡() async throws {
    let (store, _) = try upgraded()
    let records = try await store.sendRecords()
    #expect(Set(records.compactMap(\.cardID)) == [Self.ids.top, Self.ids.note])
    #expect(try await store.deliveryRequest(UUID(uuidString: "d0000000-0000-0000-0000-000000000001")!)?.cardID == Self.ids.loose)
  }

  @Test func 目标卡第一行成为项目介绍_目标卡变回普通灵感() async throws {
    let (store, _) = try upgraded()
    #expect(try await store.project(Self.ids.project)?.intro == "多 Agent 调度本月可上线")
    let goal = try #require(try await store.card(Self.ids.goal))
    #expect(goal.isTask == false && goal.isPinned == false && goal.body.hasPrefix("# 目标："))
  }

  @Test func 旧的任务表与它的同步元数据去掉_已同步的卡片元数据保留_任务卡片待上传() async throws {
    let (store, url) = try upgraded()
    let raw = try RawDB(url)
    #expect(try raw.rows("SELECT name FROM sqlite_master WHERE name = 'tasks'").isEmpty)
    #expect(try raw.rows("SELECT recordType FROM syncRecords") == [["cards"]])
    let pending = try await store.pendingSync()
    #expect(Set(pending.saves.map(\.id)).isSuperset(of: [Self.ids.top, Self.ids.sub, Self.ids.leaf, Self.ids.loose].map { $0.uuidString.lowercased() }))
    #expect(pending.deletes.isEmpty)
  }
}
