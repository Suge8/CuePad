import CloudKit
import CueTestSupport
import Foundation
import Testing
@testable import CueStore
@testable import CueSync

/// 到达日志是同步延迟实测的数据来源：一行一条，字段约定见 `ArrivalLog`，由 `apple/scripts/synclat.py` 读出。
@Suite(.timeLimit(.minutes(1))) struct ArrivalLogTests {
  let rig = try! Rig()
  let clock = ManualTiming()
  #if os(macOS)
  let device = "mac"
  #else
  let device = "phone"
  #endif

  /// 服务器时间可指定的记录（真实记录的 `modificationDate` 由服务器盖）。
  final class Dated: CKRecord, @unchecked Sendable {
    nonisolated(unsafe) var date: Date?
    override var modificationDate: Date? { date }
  }

  private func request(_ id: UUID, modifiedAt: Int64, landed: Date) -> CKRecord {
    let dated = Dated(recordType: "deliveryRequests", recordID: CKRecord.ID(recordName: id.uuidString.lowercased(), zoneID: testZone))
    dated.date = landed
    let fields: [String: SQLValue] = [
      "id": .text(id.uuidString.lowercased()), "content": .text("x"), "targetKind": .text("app"), "targetName": .text("CuePad"), "targetRef": .null,
      "hostID": .text("mac-a"), "mode": .text("send"), "cardID": .null, "taskID": .null, "status": .text("pending"),
      "resultDetail": .null, "handledBy": .null, "createdAt": .int(1_000), "completedAt": .null, "modifiedAt": .int(modifiedAt),
    ]
    return RecordMapper.record(from: SyncRow(table: .deliveryRequests, fields: fields), zoneID: testZone, base: dated)
  }

  private func makeLog() -> (ArrivalLog, AsyncStream<String>.Iterator) {
    let (lines, sink) = AsyncStream<String>.makeStream()
    let log = ArrivalLog(store: rig.store, timing: clock.timing, deviceState: { "app=active" }, write: { sink.yield($0) })
    return (log, lines.makeAsyncIterator())
  }

  @Test func 主动拉取先到_引擎稍后补拿时补记推送延迟() async throws {
    let id = UUID()
    let record = request(id, modifiedAt: 5_000, landed: clock.now.addingTimeInterval(-3))
    let (log, lines) = makeLog()
    var iterator = lines
    let rec = id.uuidString.lowercased().prefix(8)

    await log.pulled([record])
    clock.advance(.seconds(5))
    await log.engineFetchBegan(manual: false)
    await log.engineFetched([record])

    #expect(await iterator.next() == "latency arrive dev=\(device) path=pull kind=request rec=\(rec) v=5000 lag=3.00 app=active")
    #expect(await iterator.next() == "latency arrive dev=\(device) path=push kind=request rec=\(rec) v=5000 lag=8.00 pullLag=3.00 app=active")
  }

  @Test func 主动拉取先到而推送始终没来_过了五分钟记为丢失() async throws {
    let id = UUID()
    let record = request(id, modifiedAt: 5_000, landed: clock.now.addingTimeInterval(-3))
    let (log, lines) = makeLog()
    var iterator = lines

    await log.pulled([record])
    _ = await iterator.next()
    await clock.waitForSleeper()
    clock.advance(.seconds(301))

    #expect(await iterator.next() == "latency lost dev=\(device) kind=request rec=\(id.uuidString.lowercased().prefix(8)) v=5000 pullLag=3.00 after=300 app=active")
  }

  /// 本机自己调的 fetchChanges 拿走后，引擎的令牌已越过这条记录，不会再有推送：不能记成丢失。
  @Test func 本机手动拉取先带来的_不再等推送也不记丢失() async throws {
    let record = request(UUID(), modifiedAt: 5_000, landed: clock.now.addingTimeInterval(-3))
    let (log, lines) = makeLog()
    var iterator = lines

    await log.pulled([record])
    await log.engineFetchBegan(manual: true)
    await log.engineFetched([record])
    _ = await iterator.next()
    let manual = await iterator.next()
    clock.advance(.seconds(301))
    try await Task.sleep(for: .milliseconds(50))  // 没有事件可等：给（已取消的）丢失计时器一个醒来的机会，再用一条新记录收尾
    await log.engineFetched([request(UUID(), modifiedAt: 7_000, landed: clock.now)])

    #expect(manual?.contains("path=manual") == true && manual?.contains("pullLag=3.00") == true)
    #expect(await iterator.next()?.contains("v=7000") == true)  // 紧接着的就是收尾那条，中间没有 lost
  }

  @Test func 本机已有这个版本_自己写的回声或另一条路先带来的_不记到达() async throws {
    let record = request(UUID(), modifiedAt: 5_000, landed: clock.now.addingTimeInterval(-3))
    await rig.coordinator.handle(.fetched(modifications: [record], deletions: []))
    let (log, lines) = makeLog()
    var iterator = lines

    await log.engineFetchBegan(manual: false)
    await log.engineFetched([record])
    let newer = request(UUID(), modifiedAt: 6_000, landed: clock.now.addingTimeInterval(-1))
    await log.engineFetched([newer])

    #expect(await iterator.next()?.contains("v=6000") == true)  // 第一行就是新记录的，已有的那条没有行
  }
}
