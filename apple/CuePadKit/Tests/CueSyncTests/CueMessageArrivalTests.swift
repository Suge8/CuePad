import CloudKit
import CueStore
import Foundation
import Synchronization
import Testing

@testable import CueSync

/// 你在手机上对 Cue 说的话推送到不了 Mac，只经 Cue 值班那台 Mac 的拉取到达（`SyncPoller.Cadence.mac` 的节奏、
/// `ZonePuller` 的拉取，与 App 里同一条路，只换掉服务器）。同步区很大、别的设备一刻不停地写、本机的库也正忙时，
/// 话到了服务器平均约 1 秒、最坏约 2 秒（拉取间隔）就落到这台 Mac 的库里；Mac 重启后令牌还在，不重翻同步区。
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CueMessageArrivalTests {
  /// 服务器一次请求的往返（实测 CloudKit 拉一页 0.05–0.8 秒）。
  private static let roundTrip: Duration = .milliseconds(150)
  /// 同步区里已有的历史（用户库约九千条记录，多是结束了的会话状态）。
  private static let history = 4_000

  let mac = try! Rig()
  let phone = try! Rig()

  /// 一个活的同步区：记录按到达先后排成日志，令牌是日志里的位置；每次请求有往返耗时，一页至多 `page` 条。
  actor ServerZone: ZoneChangeSource {
    static let page = 400
    private var log: [CKRecord] = []
    private let tokenTaken: AsyncStream<Void>.Continuation
    /// 拉取器第一次带整条记录来拉：令牌已经取好（没有令牌时对账那一遍只带版本）。
    let firstFullPull: AsyncStream<Void>

    init() { (firstFullPull, tokenTaken) = AsyncStream.makeStream() }

    func append(_ records: [CKRecord]) { log += records }

    func changes(since token: Data?, keys: [String]?) async throws -> ZoneChangeBatch {
      if keys == nil { tokenTaken.yield() }
      try await Task.sleep(for: CueMessageArrivalTests.roundTrip)
      let from = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
      let end = min(log.count, from + Self.page)
      return ZoneChangeBatch(
        modifications: Array(log[from..<end]), deletions: [], token: Data(String(end).utf8), moreComing: end < log.count)
    }

    func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] {
      try await Task.sleep(for: CueMessageArrivalTests.roundTrip)
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

  /// 有历史、别的设备一刻不停写进来的同步区，加上本机正忙的库；返回停下这些的办法。
  private func busy(_ zone: ServerZone) async -> @Sendable () -> Void {
    await zone.append((0..<Self.history).map { Self.piState("old-\($0)", state: "ended", at: 1_000) })
    let store = mac.store
    let elsewhere = Task {
      var tick: Int64 = 2_000
      while !Task.isCancelled {
        tick += 1
        await zone.append((0..<5).map { Self.piState("there-\($0)", state: tick.isMultiple(of: 2) ? "thinking" : "tool", at: tick) })
        try? await Task.sleep(for: .milliseconds(20))
      }
    }
    let here = Task {
      let recorder = PiStateRecorder(store: store, hostID: "mac")
      var round = 0
      while !Task.isCancelled {
        round += 1
        for index in 0..<10 { try? await recorder.update(sessionID: "here-\(index)", state: round.isMultiple(of: 2) ? .thinking : .tool, title: "会话") }
        try? await Task.sleep(for: .milliseconds(20))
      }
    }
    return {
      elsewhere.cancel()
      here.cancel()
    }
  }

  /// Cue 在这台值班时的拉取（会话都关着，也没有在路上的请求）。
  private func poll(_ zone: ServerZone) -> Task<Void, Never> {
    let puller = ZonePuller(source: zone, coordinator: mac.coordinator)
    let waiting = AsyncStream<SyncPoller.Cadence?> { $0.yield(.mac(waiting: true)) }
    return Task { await SyncPoller().run(while: waiting) { try? await puller.pull() } }
  }

  /// 手机上说一句：写进手机的库，上传后的服务器记录。
  private func said(_ text: String) async throws -> (id: UUID, record: CKRecord) {
    let message = try await phone.store.addCueMessage(.you, text: text)
    return (message.id, try #require(await phone.coordinator.record(for: phone.recordID(message.id))))
  }

  private func arrived(_ id: UUID, within limit: Duration) async throws {
    try await eventually("这句话到这台 Mac", timeout: limit) { try await mac.store.cueMessagesToDeliver().contains { $0.id == id } }
  }

  /// 拉取间隔 2 秒加一次拉取（往返）和落库的余量。
  private static let steadyLimit: Duration = .milliseconds(2_600)

  @Test func whatYouSayOnThePhoneReachesTheCueMacWithinTheInterval() async throws {
    let zone = ServerZone()
    let stop = await busy(zone)
    defer { stop() }
    let polling = poll(zone)
    defer { polling.cancel() }
    var taken = zone.firstFullPull.makeAsyncIterator()
    await taken.next()

    var slowest = Duration.zero
    for round in 0..<5 {
      let (id, record) = try await said("第 \(round) 句")
      let start = ContinuousClock.now
      await zone.append([record])
      try await arrived(id, within: Self.steadyLimit)
      slowest = max(slowest, ContinuousClock.now - start)
      try await Task.sleep(for: .milliseconds(370))  // 下一句落在拉取的另一个相位
    }
    print("手机上说的话到服务器起落到 Mac 的库：最慢 \(slowest)")
  }

  /// Mac 关着时说的：重启后从上次的令牌接着拉，第一次拉就到，不先翻一遍同步区。
  @Test func whatYouSaidWhileTheMacWasOffArrivesOnTheFirstPullAfterARestart() async throws {
    let zone = ServerZone()
    let stop = await busy(zone)
    defer { stop() }
    try await ZonePuller(source: zone, coordinator: mac.coordinator).pull()  // 上次运行：令牌存在库里
    let (id, record) = try await said("Mac 关着时说的")
    await zone.append([record])

    let start = ContinuousClock.now
    let polling = poll(zone)
    defer { polling.cancel() }
    try await arrived(id, within: Self.steadyLimit)
    print("Mac 重启后：开拉后 \(ContinuousClock.now - start) 到")
  }
}
