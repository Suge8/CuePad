import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 正式版的故障：被 CloudKit 限流（429 带 Retry-After）后照样发拉取、门铃密钥，限流按设备算，越发被限得越久。
/// 两台设备连同步测量用的模拟云（`SharedCloud`：按 CloudKit 的设备限流回 429、记下到了服务器的每个请求），同步代码照真的跑。
struct ThrottleTests {
  static let retryAfter = 1.0
  let directory = TestLibraries.makeDirectory()
  let mac = try! Fixture()
  let phone = try! Fixture()

  /// 限流期间立即同步、马上传、按提交的上传、取门铃密钥、进后台前的发送都不到服务器；到点后限流时记下的那条照样传上去、到了另一台。
  @Test func nothingReachesTheServerBeforeRetryAfterAndTheBacklogArrivesAfterwards() async throws {
    try await SharedCloud(directory: directory).saveZone()  // 先建好云的库文件：两台同时头一次打开会撞上切 WAL 的锁
    let macSync = connect(mac), phoneSync = connect(phone)
    for sync in [macSync, phoneSync] {
      await sync.start()
      try await sync.syncNow()
      await sync.push()  // 对过最低对端版本：之后没有这台自己发起的请求
    }

    try JSONEncoder().encode(["until": Date.now.timeIntervalSince1970 + 60, "retryAfter": 1]).write(to: directory.appending(path: "throttle.json"))
    await #expect(throws: CKError.self) { try await macSync.syncNow() }
    try FileManager.default.removeItem(at: directory.appending(path: "throttle.json"))  // 只限这一次：之后被拒只因没守 Retry-After

    let card = try await mac.store.createCard(body: "限流时记的")
    let name = card.id.uuidString.lowercased()
    _ = await macSync.send(recordNames: [name])
    try? await macSync.syncNow()
    _ = try? await macSync.relaySecret()
    await macSync.push()

    _ = try await eventually(mac.store, { try $0.pendingSync().saves.map(\.id) }, until: { !$0.contains(name) })
    try await phoneSync.syncNow()
    #expect(try await phone.store.card(card.id)?.body == "限流时记的")

    // 服务器记下的请求：回了 429 的那一次之后、它给的 Retry-After 到点之前到的
    let early = try RawDB(directory.appending(path: "cloud.sqlite")).rows("""
      SELECT r.kind FROM requests r JOIN requests refused ON refused.result = '429'
      WHERE r.rowid > refused.rowid AND r.t < refused.t + refused.wait
      """).map { $0[0] }
    #expect(early == [], "Retry-After 到点前到了服务器的请求")

    await macSync.stop()
    await phoneSync.stop()
  }

  private func connect(_ device: Fixture) -> CloudSync {
    CloudSync(store: device.store) { [directory] in SharedCloud(directory: directory) }
  }
}
