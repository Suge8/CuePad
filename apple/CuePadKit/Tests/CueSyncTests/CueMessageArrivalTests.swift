import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 你在手机上对 Cue 说的话推送到不了 Mac，只经 Cue 值班那台 Mac 的拉取到达（`SyncPoller.Cadence.mac` 的节奏、
/// `ZonePuller` 的拉取，与 App 里同一条路，只换掉服务器；Cue 值班算在等由 `AppServices.pollingCadence` 定，见 App 的 `MacSyncTests`）。
/// 同步区很大、别的设备一刻不停地写、本机的库也正忙时，话到了服务器之后的下一次拉取就落到这台 Mac 的库里，拉取每 2 秒一次
/// （平均约 1 秒、最坏约 2 秒）。
/// 节奏走可控的时钟：按拉了几次、过了多少虚拟时间判断，不看墙上时钟。
@Suite(.timeLimit(.minutes(1)))
struct CueMessageArrivalTests {
  /// 同步区里已有的历史（用户库约九千条记录，多是结束了的会话状态）。
  private static let history = 4_000
  /// 两次拉取之间别的设备写来的会话状态（要翻几页才到你的话）。
  private static let churn = 1_000

  let mac = try! Rig()
  let phone = try! Rig()
  let time = ManualTiming()

  /// 一个同步区：记录按到达先后排成日志，令牌是日志里的位置，一页至多 `page` 条。
  actor ServerZone: ZoneChangeSource {
    static let page = 400
    private var log: [CKRecord] = []

    func append(_ records: [CKRecord]) { log += records }

    func changes(since token: Data?, keys: [String]?) async throws -> ZoneChangeBatch {
      let from = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
      let end = min(log.count, from + Self.page)
      return ZoneChangeBatch(
        modifications: Array(log[from..<end]), deletions: [], token: Data(String(end).utf8), moreComing: end < log.count)
    }

    func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] {
      let wanted = Set(ids)
      var latest: [CKRecord.ID: CKRecord] = [:]
      for record in log where wanted.contains(record.recordID) { latest[record.recordID] = record }
      return Array(latest.values)
    }
  }

  private static func piState(_ sessionID: String, state: String, at: Int64) -> CKRecord {
    remoteRecord(.piSessionStates, id: PiSessionState.recordID(sessionID: sessionID), [
      "sessionID": .text(sessionID), "hostID": .text("mac-b"), "title": .text(sessionID), "projectID": .null,
      "state": .text(state), "detail": .null, "stateSince": .int(at), "createdAt": .int(at),
      "modifiedAt": .int(at), "notify": .null, "folder": .null, "lastPrompt": .null, "lastReply": .null,
      "question": .null, "busySince": .null,
    ])
  }

  private static var oldSessions: [CKRecord] { (0..<history).map { piState("old-\($0)", state: "ended", at: 1_000) } }

  /// 别的设备又写来一批会话状态。
  private static func elsewhere(_ round: Int) -> [CKRecord] {
    (0..<churn).map { piState("there-\($0 % 20)", state: $0.isMultiple(of: 2) ? "thinking" : "tool", at: Int64(2_000 + round * churn + $0)) }
  }

  /// 本机的库一刻不停地写（十个会话的状态），直到任务取消。
  private func busyHere() -> Task<Void, Never> {
    let store = mac.store
    return Task {
      let recorder = PiStateRecorder(store: store, hostID: "mac")
      var round = 0
      while !Task.isCancelled {
        round += 1
        for index in 0..<10 { try? await recorder.update(sessionID: "here-\(index)", state: round.isMultiple(of: 2) ? .thinking : .tool, title: "会话") }
        await Task.yield()
      }
    }
  }

  /// Cue 在这台值班时的拉取（会话都关着，也没有在路上的请求），节奏走可控的时钟。
  private func poll(_ zone: ServerZone) -> Task<Void, Never> {
    let puller = ZonePuller(source: zone, coordinator: mac.coordinator)
    let waiting = AsyncStream<SyncPoller.Cadence?> { $0.yield(.mac(waiting: true)) }
    let poller = SyncPoller(timing: time.timing)
    return Task { await poller.run(while: waiting) { try? await puller.pull() } }
  }

  /// 拉取在等下一次：这一次已经拉完、落进库了。
  private func pulled() async { await time.waitForSleeper() }

  /// 手机上说一句：写进手机的库，上传后的服务器记录。
  private func said(_ text: String) async throws -> (id: UUID, record: CKRecord) {
    let message = try await phone.store.addCueMessage(.you, text: text)
    return (message.id, try #require(await phone.coordinator.record(for: phone.recordID(message.id))))
  }

  private func arrived(_ id: UUID) async throws -> Bool {
    try await mac.store.cueMessagesToDeliver().contains { $0.id == id }
  }

  @Test func whatYouSayOnThePhoneArrivesWithTheNextPull() async throws {
    let zone = ServerZone()
    await zone.append(Self.oldSessions)
    let busy = busyHere()
    defer { busy.cancel() }
    let polling = poll(zone)
    defer { polling.cancel() }
    await pulled()  // 开始在等就拉第一次（取令牌）

    for round in 0..<5 {
      let (id, record) = try await said("第 \(round) 句")
      await zone.append(Self.elsewhere(2 * round) + [record] + Self.elsewhere(2 * round + 1))
      #expect(try await !arrived(id))

      time.advance(.milliseconds(1_999))
      #expect(time.sleeperCount == 1)  // 不到 2 秒不拉
      time.advance(.milliseconds(1))
      await pulled()
      #expect(try await arrived(id), "第 \(round) 句没随下一次拉取到")
    }
  }
}
