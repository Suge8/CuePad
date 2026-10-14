import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

@Suite struct CrossProcessSyncTests {
  /// 命令行（另一个进程）写的记录也会被 App 传上去。
  @Test(.timeLimit(.minutes(1)))
  func anotherProcessWriteIsUploaded() async throws {
    let rig = try Rig()
    let server = FakeUploader()
    let sender = RecordSender(uploader: server, coordinator: rig.coordinator)
    await sender.start()
    let cli = try CueStore(url: rig.fixture.url)  // 另一个进程

    let card = try await cli.createCard(in: nil, body: "written by cli")
    await server.uploaded(rig.id(card.id))

    await sender.stop()
  }
}
