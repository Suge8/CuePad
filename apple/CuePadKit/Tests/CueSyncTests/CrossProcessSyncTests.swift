import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

@Suite struct CrossProcessSyncTests {
  @Test(.timeLimit(.minutes(1)))
  func anotherProcessWriteTriggersReconcile() async throws {
    let rig = try Rig()
    try await rig.coordinator.start()
    let cli = try CueStore(url: rig.fixture.url)  // 另一个进程

    let card = try await cli.createCard(in: nil, body: "written by cli")
    let id = rig.id(card.id)
    await rig.queue.waitUntil { saves, _ in saves.contains(id) }

    await rig.coordinator.stop()
  }
}
