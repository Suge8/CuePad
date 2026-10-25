import CloudKit
import CueStore
import Testing

@testable import CueSync

/// 待推送由数据库状态推导（新记录、编辑后的记录、已删除但服务器还有的记录），发送者跟着本机提交把它们传上去。
@Suite struct PendingTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  /// 本机与另一个进程（命令行）的写入、删除，开始同步后都自己传上去。
  @Test
  func localAndOtherProcessWritesAreUploadedAutomaticallyOnceStarted() async throws {
    let server = FakeUploader()
    let sender = RecordSender(uploader: server, coordinator: rig.coordinator)
    await sender.start()
    let cli = try CueStore(location: .isolated(rig.fixture.directory))  // 另一个进程
    let card = try await cli.createCard(body: "written by cli")
    await server.uploaded(rig.id(card.id))

    try await store.purgeCard(card.id)
    await server.deleted(rig.id(card.id))
    await sender.stop()
  }

  /// 上一版还在上传时记录又改了：上一版的结果回来后，新的这一版接着传上去，不丢。
  @Test
  func anEditMadeWhileThePreviousVersionWasUploadingIsUploadedAfterIt() async throws {
    let server = FakeUploader(holding: true)
    let sender = RecordSender(uploader: server, coordinator: rig.coordinator)
    await sender.start()
    let card = try await store.createCard(body: "v1")
    let id = rig.id(card.id)
    await server.uploaded(id)

    try await Task.sleep(for: .milliseconds(3))
    try await store.updateCard(card.id) { $0.body = "v2" }
    await server.release()

    await server.waitUntil { batches in batches.filter { $0.saves.contains(id) }.count == 2 }
    await sender.flush()  // 替身在第二批上传开始时就放行等待，这一批的结果落账要等这一轮结束
    #expect(try await rig.reconcileDelta().saves.isEmpty)
    await sender.stop()
  }
}
