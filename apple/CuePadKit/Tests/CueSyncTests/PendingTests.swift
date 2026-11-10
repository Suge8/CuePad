import CloudKit
import CueStore
import Testing

@testable import CueSync

@Suite struct PendingTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  @Test
  func localAndOtherProcessWritesAreUploadedAutomaticallyOnceStarted() async throws {
    let server = FakeUploader()
    let sender = RecordSender(uploader: server, coordinator: rig.coordinator)
    await sender.start()
    let cli = try CueStore(location: .isolated(rig.fixture.directory))  // 另一个进程
    let card = try await cli.createCard(body: "written by cli")
    try await server.uploaded(rig.id(card.id))

    try await store.purgeCard(card.id)
    try await server.deleted(rig.id(card.id))
    await sender.stop()
  }

  @Test
  func anEditMadeWhileThePreviousVersionWasUploadingIsUploadedAfterIt() async throws {
    // 先写下再起发送者：替身扣住的是第一批，起来时库里还没有它的话，第一批只带走默认项目、被扣住，排在后面的轮次一直等它
    let card = try await store.createCard(body: "v1")
    let id = rig.id(card.id)
    let server = FakeUploader(holding: true)
    let sender = RecordSender(uploader: server, coordinator: rig.coordinator)
    await sender.start()
    try await server.uploaded(id)

    await nextMillisecond()
    try await store.updateCard(card.id) { $0.body = "v2" }
    await server.release()

    try await server.waitUntil("同一条记录上传两批") { batches in batches.filter { $0.saves.contains(id) }.count == 2 }
    await sender.flush()  // 替身在第二批上传开始时就放行等待，这一批的结果落账要等这一轮结束
    #expect(try await rig.reconcileDelta().saves.isEmpty)
    await sender.stop()
  }
}
