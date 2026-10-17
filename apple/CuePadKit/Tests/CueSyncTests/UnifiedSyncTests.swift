import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 合并后的同步：服务器上留着的旧 tasks 记录（退役类型，未升级的设备还会写）一律跳过、不报问题；
/// 远端把某张卡挂到了一个已不再"要做"的灵感下（别处并发取消了要做），按"只有任务能当上级"收敛：提到那个灵感的位置。
@Suite struct UnifiedSyncTests {
  let rig = try! Rig()
  var store: CueStore { rig.store }

  /// 手机上从灵感开的新会话：Mac 开好后同步来的会话记录带着认领标识，手机这边同一处认领，灵感关联到那个会话。
  @Test func 同步来的会话记录带认领标识_手机上发起的灵感关联到它() async throws {
    let idea = try await store.createCard(in: nil, body: "看一下重连")
    let project = try await store.createProject(name: "圆桌", color: "#111")
    _ = try await store.requestLaunch(PiLaunch(project: project.id, prompt: idea.body, token: "t-phone"), title: "圆桌", on: "mac-a", card: idea.id)

    let state = remoteRecord(.piSessionStates, id: PiSessionState.recordID(sessionID: "s-new"), [
      "sessionID": .text("s-new"), "hostID": .text("mac-a"), "title": .text("圆桌"), "projectID": .null,
      "state": .text("thinking"), "detail": .null, "stateSince": .int(1_000), "createdAt": .int(1_000),
      "modifiedAt": .int(1_000), "notify": .null, "folder": .null, "lastPrompt": .null, "lastReply": .null,
      "question": .null, "busySince": .null, "launchToken": .text("t-phone"),
    ])
    try await rig.coordinator.pulled([state], [])

    #expect(try await store.card(idea.id)?.piSessionID == "s-new")
  }
}
