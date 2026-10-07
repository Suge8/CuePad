import CueStore
import CueTestSupport
import Foundation
import Testing

/// 真实旧库（结构版本 12，由合并前的版本写出：项目带目标卡、三级任务、带任务的发送记录与投送请求、已同步过的任务）升级：
/// 任务变成要做的卡片（状态、上级、会话、排序照搬），发送记录与投送请求指向同一张卡，
/// 目标卡第一行（去掉"目标："）填进项目介绍、目标卡变回普通灵感，tasks 表与它的同步元数据去掉。
/// 卡片的 id 不能沿用任务的：服务器上同名的 tasks 记录不能改类型（"invalid attempt to update record from type 'tasks' to 'cards'"），
/// 沿用就永远上传不了；新 id 由旧 id 算出，各设备各自升级得到同一个。
@Suite struct UnifyMigrationTests {
  private static let ids = (
    project: UUID(uuidString: "F98C7363-E9A0-4A95-9974-6CBD9F39CB9B")!, goal: UUID(uuidString: "548C9C32-6F6F-4B69-B768-F7FE2556F382")!,
    note: UUID(uuidString: "D84CF3EC-C728-4590-A55D-28E8CC11A1BB")!, top: UUID(uuidString: "2DB1885D-588B-4870-AA18-239681FDF91C")!,
    sub: UUID(uuidString: "9BC928A5-DA1D-46F1-8797-5A76AAFEFB3B")!, leaf: UUID(uuidString: "DB18792B-4414-4593-82AB-85748CB2CC0D")!,
    loose: UUID(uuidString: "8B4DF51B-0BD4-479E-BA46-3D957E30FB39")!)
  private static let oldTaskIDs = [ids.top, ids.sub, ids.leaf, ids.loose]

  private func upgraded() throws -> (CueStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "unify-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "cuepad.db")
    let fixture = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/library-v12.sqlite")
    try FileManager.default.copyItem(at: fixture, to: url)
    return (try CueStore(url: url), url)
  }

  /// 升级后的任务（按正文取：id 已换）。
  private func tasks(_ store: CueStore) async throws -> [String: Card] {
    Dictionary(uniqueKeysWithValues: try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks).map { ($0.body, $0) })
  }

  @Test func 任务变成要做的卡片_状态上级会话照搬() async throws {
    let (store, _) = try upgraded()
    let cards = try await tasks(store)
    let top = try #require(cards["修 scheduler 重连排序"])
    let sub = try #require(cards["改成按首次加入时间排序"])
    let leaf = try #require(cards["补 3 个重连用例"])
    #expect(top.isTask && top.projectID == Self.ids.project)
    #expect(top.status == .inProgress && top.piSessionID == "s1")
    #expect(sub.parentID == top.id && leaf.parentID == sub.id)
    #expect(leaf.status == .done)
    #expect(cards["续费域名"]?.status == .inProgress)
    #expect(try await store.taskCounts()[Self.ids.project] == TaskCounts(inProgress: 1, todo: 0, done: 0))
  }

  @Test func 任务卡片换了新_id_各设备升级得到同一个() async throws {
    let (store, url) = try upgraded()
    let (other, _) = try upgraded()
    for old in Self.oldTaskIDs { #expect(try await store.card(old) == nil) }
    let indexed = Set(try RawDB(url).rows("SELECT refID FROM searchIndex WHERE kind = 'card'").flatMap { $0 })
    #expect(indexed.isDisjoint(with: Self.oldTaskIDs.map { $0.uuidString.lowercased() }) && indexed.count == 7)  // 搜索索引跟着换
    let ids = try await tasks(store).values.map(\.id)
    #expect(ids.count == 4 && Set(ids).isDisjoint(with: Self.oldTaskIDs))
    #expect(Set(ids) == Set(try await tasks(other).values.map(\.id)))
  }

  @Test func 发送记录与投送请求指向同一张卡() async throws {
    let (store, _) = try upgraded()
    let cards = try await tasks(store)
    let records = try await store.sendRecords()
    #expect(Set(records.compactMap(\.cardID)) == [try #require(cards["修 scheduler 重连排序"]).id, Self.ids.note])
    #expect(try await store.deliveryRequest(UUID(uuidString: "d0000000-0000-0000-0000-000000000001")!)?.cardID == cards["续费域名"]?.id)
  }

  @Test func 目标卡第一行成为项目介绍_目标卡变回普通灵感() async throws {
    let (store, _) = try upgraded()
    #expect(try await store.project(Self.ids.project)?.intro == "多 Agent 调度本月可上线")
    let goal = try #require(try await store.card(Self.ids.goal))  // 不是任务的卡片 id 不变
    #expect(goal.isTask == false && goal.isPinned == false && goal.body.hasPrefix("# 目标："))
  }

  @Test func 旧的任务表与它的同步元数据去掉_已同步的卡片元数据保留_任务卡片待上传() async throws {
    let (store, url) = try upgraded()
    let raw = try RawDB(url)
    #expect(try raw.rows("SELECT name FROM sqlite_master WHERE name = 'tasks'").isEmpty)
    #expect(try raw.rows("SELECT recordType FROM syncRecords") == [["cards"]])
    let pending = try await store.pendingSync()
    let taskCards = try await tasks(store).values.map { $0.id.uuidString.lowercased() }
    #expect(Set(pending.saves.map(\.id)).isSuperset(of: taskCards))
    #expect(pending.deletes.isEmpty)
  }
}
