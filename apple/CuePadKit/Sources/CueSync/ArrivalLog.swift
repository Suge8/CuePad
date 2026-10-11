import CloudKit
import CueStore
import Foundation
import os

/// 同步延迟的唯一埋点：别的设备写来、本机在等的记录（`ZoneChangePuller.awaitedTables`：投送请求与 Pi 会话状态）几时到本机、经哪条路。
/// 一条到达一行日志（子系统 com.sugeh.cuepad，类别 sync-latency，.notice 级、Release 里也有，不含内容），分析在 `apple/scripts/synclat.py`
/// （`xc.sh synclat`）；字段是这两处之间的约定：
///
/// `latency arrive dev=mac|phone path=push|pull|manual kind=request|result|session rec=<记录名前 8 位> v=<记录版本 modifiedAt>
/// server=<服务器时间，秒> at=<本机到达时刻，秒> lag=<at - server> [pullLag=<主动拉取先到时的 lag>] <设备状态 key=value …>`
/// （server、at 是 1970 年起的秒数，三位小数）
///
/// `latency lost … after=<秒>`：主动拉取先拿到后，引擎过了 `lostAfter` 仍没经推送带来。
/// `latency superseded … after=<秒>`：同一条记录这期间已有更新的版本（如 Mac 领取、执行完又写回），引擎只会带来最新版本，
/// 旧版本的推送延迟量不到，既不算延迟也不算丢失。
///
/// 路径：`push` 是 CKSyncEngine 自己调度的拉取（推送触发，也含引擎的启动与周期拉取，所以是推送延迟的上界）；`manual` 是本机调
/// `engine.fetchChanges`（回前台、唤醒）；`pull` 是 `ZoneChangePuller` 的主动拉取。主动拉取先到的记录要等引擎稍后补拿，补拿时再记
/// 一行 push 并带上 `pullLag`，两条路各自的延迟就都有了；`manual` 先到的，引擎的令牌已越过它，不会再有推送到达，不记丢失。
///
/// 时钟：起点是服务器记的 `modificationDate`，终点是本机时钟。两台设备都对时，误差一般在零点几秒内，出现负数就是这个误差；
/// 看 p90 这个量级（几秒）时可以忽略，看亚秒级别的差别不可靠。
actor ArrivalLog {
  enum Path: String, Sendable { case push, pull, manual }

  /// 主动拉取先到后，超过这么久引擎仍没带来，记为推送丢失。
  static let lostAfter: Duration = .seconds(300)

  private static let logger = Logger(subsystem: "com.sugeh.cuepad", category: "sync-latency")

  private struct Arrival {
    let table: Table
    let name: String
    let version: Int64
    let server: Date
    let kind: String

    init?(_ record: CKRecord) {
      guard let table = Table(rawValue: record.recordType), ZoneChangePuller.awaitedTables.contains(table),
            let server = record.modificationDate, let version = (record["modifiedAt"] as? NSNumber)?.int64Value
      else { return nil }
      self.table = table
      name = record.recordID.recordName
      self.version = version
      self.server = server
      kind = switch table {
      case .deliveryRequests: [DeliveryStatus.succeeded.rawValue, DeliveryStatus.failed.rawValue].contains(record["status"] as? String) ? "result" : "request"
      default: "session"
      }
    }
  }

  /// 主动拉取先拿到、还在等推送的版本（每条记录只等最新拿到的那个版本）。
  private struct Waiting {
    var arrival: Arrival
    var pullLag: Double
    var state: String
    var lost: Task<Void, Never>
  }

  private let store: CueStore
  private let timing: Timing
  private let lostAfter: Duration
  private let deviceState: @Sendable () -> String
  private let write: @Sendable (String) -> Void
  private var waiting: [String: Waiting] = [:]
  private var fetchIsManual = false

  /// `deviceState`：到达那一刻本机的状态（前台/后台、网络、电源……，`key=value` 以空格分隔），由 App 提供。
  init(
    store: CueStore, timing: Timing = .system, lostAfter: Duration = ArrivalLog.lostAfter,
    deviceState: @escaping @Sendable () -> String = { "" },
    write: @escaping @Sendable (String) -> Void = { line in ArrivalLog.logger.notice("\(line, privacy: .public)") }
  ) {
    self.store = store
    self.timing = timing
    self.lostAfter = lostAfter
    self.deviceState = deviceState
    self.write = write
  }

  /// 引擎开始一轮拉取：`manual` 是本机自己调的 `fetchChanges`，否则是引擎自己调度的（推送或启动、周期）。
  func engineFetchBegan(manual: Bool) { fetchIsManual = manual }

  func engineFetched(_ records: [CKRecord]) async {
    await note(records, via: fetchIsManual ? .manual : .push)
  }

  func pulled(_ records: [CKRecord]) async {
    await note(records, via: .pull)
  }

  private func note(_ records: [CKRecord], via path: Path) async {
    let arrivals = records.compactMap(Arrival.init)
    guard !arrivals.isEmpty else { return }
    // 本机已有这个版本（自己写的回声、另一条路先带来的）不算到达；已在等推送的版本不受此限，它正是在等引擎补拿
    var known: [Table: [String: Int64]] = [:]
    for table in Set(arrivals.map(\.table)) {
      do {
        known[table] = try await store.modifiedAts(of: arrivals.filter { $0.table == table }.map(\.name), in: table)
      } catch {
        Self.logger.error("读本机记录版本失败，这一批不记到达：\(String(describing: error), privacy: .public)")
        return
      }
    }
    for arrival in arrivals {
      if let pending = waiting[arrival.name] {
        if arrival.version < pending.arrival.version { continue }
        if arrival.version == pending.arrival.version {
          guard path != .pull else { continue }
          pending.lost.cancel()
          waiting[arrival.name] = nil
          write(line("arrive", arrival, path: path, lag: lag(of: arrival), extra: "pullLag=\(fixed(pending.pullLag))", state: pending.state))
          continue
        }
        pending.lost.cancel()  // 更新的版本先到了：旧版本的推送不会再来
        waiting[arrival.name] = nil
        write(line("superseded", pending.arrival, path: nil, lag: nil, extra: "pullLag=\(fixed(pending.pullLag))", state: pending.state))
      }
      guard known[arrival.table]?[arrival.name].map({ $0 < arrival.version }) ?? true else { continue }
      let state = deviceState()
      let lag = lag(of: arrival)
      write(line("arrive", arrival, path: path, lag: lag, state: state))
      if path == .pull { waiting[arrival.name] = Waiting(arrival: arrival, pullLag: lag, state: state, lost: lostTimer(arrival)) }
    }
  }

  private func lostTimer(_ arrival: Arrival) -> Task<Void, Never> {
    Task { [timing, lostAfter] in
      guard (try? await timing.sleep(lostAfter)) != nil else { return }
      await self.expire(arrival)
    }
  }

  /// 过了期限引擎仍没带来这个版本：本机已有更新的版本就是被取代（量不到），否则是推送丢失。
  private func expire(_ arrival: Arrival) async {
    guard let pending = waiting[arrival.name], pending.arrival.version == arrival.version else { return }
    waiting[arrival.name] = nil
    let newest = (try? await store.modifiedAts(of: [arrival.name], in: arrival.table))?[arrival.name]
    let event = newest.map { $0 > arrival.version } == true ? "superseded" : "lost"
    write(line(event, arrival, path: nil, lag: nil, extra: "pullLag=\(fixed(pending.pullLag)) after=\(Int(lostAfter.components.seconds))", state: pending.state))
  }

  private func lag(of arrival: Arrival) -> Double { timing.now().timeIntervalSince(arrival.server) }

  private func fixed(_ value: Double) -> String { String(format: "%.2f", value) }

  private func line(_ event: String, _ arrival: Arrival, path: Path?, lag: Double?, extra: String = "", state: String) -> String {
    #if os(macOS)
    let device = "mac"
    #else
    let device = "phone"
    #endif
    var fields = ["latency", event, "dev=\(device)"]
    if let path { fields.append("path=\(path.rawValue)") }
    fields += ["kind=\(arrival.kind)", "rec=\(arrival.name.prefix(8))", "v=\(arrival.version)"]
    fields.append("server=\(String(format: "%.3f", arrival.server.timeIntervalSince1970))")
    if let lag {
      fields.append("at=\(String(format: "%.3f", timing.now().timeIntervalSince1970))")
      fields.append("lag=\(fixed(lag))")
    }
    return (fields + [extra, state]).filter { !$0.isEmpty }.joined(separator: " ")
  }
}
