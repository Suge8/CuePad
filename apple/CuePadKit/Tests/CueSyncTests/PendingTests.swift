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
    await server.uploaded(rig.id(card.id))

    try await store.purgeCard(card.id)
    await server.deleted(rig.id(card.id))
    await sender.stop()
  }

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
