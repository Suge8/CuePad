import Foundation

/// 一次往返的时间分解（秒）。除 `rtt` 外，缺少对应时序数据时为 nil。
public struct ProbeSample: Equatable, Sendable {
  public var seq: Int
  /// 发起端写入 ping → 收到并应用 pong，全在发起端时钟下。
  public var rtt: Double
  /// 发起端写入 → 上传完成。
  public var upload: Double?
  /// 对端开始拉取 → 应用 ping（对端时钟）。
  public var peerPull: Double?
  /// 对端应用 ping → 写出 pong（对端时钟）。
  public var peerProcessing: Double?
  /// 发起端开始拉取 → 应用 pong。
  public var myPull: Double?
  /// 其余：服务器处理、推送送达、对端上传（其中推送迟迟不到是最大的可能）。
  public var remainder: Double?

  public init(seq: Int, rtt: Double, upload: Double?, peerPull: Double?, peerProcessing: Double?, myPull: Double?, remainder: Double?) {
    self.seq = seq
    self.rtt = rtt
    self.upload = upload
    self.peerPull = peerPull
    self.peerProcessing = peerProcessing
    self.myPull = myPull
    self.remainder = remainder
  }
}

public struct Distribution: Equatable, Sendable {
  public var count: Int
  public var p50: Double
  public var p95: Double
  public var max: Double

  /// 最近秩百分位（不插值）；没有数据返回 nil。
  public static func of(_ values: [Double]) -> Distribution? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    func rank(_ p: Double) -> Double { sorted[Swift.max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1)] }
    return Distribution(count: sorted.count, p50: rank(0.5), p95: rank(0.95), max: sorted[sorted.count - 1])
  }
}

/// 延迟主要花在哪。
public enum DominantDelay: Equatable, Sendable {
  /// 推送（或服务器/网络）迟迟没到：拉取本身很快，大部分时间在等。
  case pushWait
  /// 推送到了，但拉取（拉取开始到应用完成）慢。
  case slowPull
}

/// 一组探针的结果：一个发起方向（`label`）、一种前后台状态（`appState`）。
public struct ProbeReport: Equatable, Sendable {
  public var label: String
  public var appState: String
  public var samples: [ProbeSample]
  public var timeouts: Int

  public init(label: String, appState: String, samples: [ProbeSample], timeouts: Int) {
    self.label = label
    self.appState = appState
    self.samples = samples
    self.timeouts = timeouts
  }

  public var rtt: Distribution? { Distribution.of(samples.map(\.rtt)) }
  public var upload: Distribution? { Distribution.of(samples.compactMap(\.upload)) }
  public var peerPull: Distribution? { Distribution.of(samples.compactMap(\.peerPull)) }
  public var myPull: Distribution? { Distribution.of(samples.compactMap(\.myPull)) }
  public var remainder: Distribution? { Distribution.of(samples.compactMap(\.remainder)) }

  /// 拉取（两端合计）与剩余等待相比，谁占大头（按中位数）。
  public var dominantDelay: DominantDelay? {
    let pulls = samples.compactMap { sample in sample.peerPull.flatMap { peer in sample.myPull.map { peer + $0 } } }
    guard let pull = Distribution.of(pulls), let rest = remainder else { return nil }
    return rest.p50 >= pull.p50 ? .pushWait : .slowPull
  }

  public var description: String {
    func line(_ name: String, _ stats: Distribution?) -> String {
      guard let stats else { return "  \(name): 无数据" }
      return String(format: "  %@: p50 %.3fs  p95 %.3fs  最大 %.3fs（%d 条）", name, stats.p50, stats.p95, stats.max, stats.count)
    }
    var lines = ["探针 \(label)（\(appState)）：成功 \(samples.count)，超时 \(timeouts)"]
    lines += [line("往返", rtt), line("上传", upload), line("对端拉取", peerPull), line("本端拉取", myPull), line("推送/网络等待", remainder)]
    switch dominantDelay {
    case .pushWait?: lines.append("  主要延迟：推送/网络等待（推送未到或迟到，拉取本身不慢）")
    case .slowPull?: lines.append("  主要延迟：拉取（推送到了，但拉取开始到应用完成慢）")
    case nil: break
    }
    return lines.joined(separator: "\n")
  }
}

/// 两端往返延迟探针。发起端 `run` 写 ping 并等 pong；对端 `startResponding` 后，每收到 ping 立即写 pong 并带上
/// 它自己的拉取开始/应用时刻（对端时钟）。往返时间只用发起端的同一个时钟计算，不受两台设备时钟差影响。
/// 探针记录是普通同步记录，用完即删。要看另一个方向，对调两端角色再跑一次。
public actor LatencyProbe {
  private let store: CueStore
  private let label: String
  private let log: SyncTimingLog
  private let timing: Timing
  private var responder: Task<Void, Never>?

  public init(store: CueStore, label: String, log: SyncTimingLog, timing: Timing = .system) {
    self.store = store
    self.label = label
    self.log = log
    self.timing = timing
  }

  // MARK: 对端

  public func startResponding() {
    guard responder == nil else { return }
    responder = Task { [store, label] in
      do {
        for try await pings in store.observe([.probes], { [label] in try $0.unansweredPings(for: label) }) {
          for ping in pings { await self.answer(ping) }
        }
      } catch {}
    }
  }

  public func stopResponding() {
    responder?.cancel()
    responder = nil
  }

  private func answer(_ ping: Probe) async {
    let fetch = await bounded(.seconds(2)) { [log] in await log.waitForFetch(of: ping.id.uuidString.lowercased()) }
    let pong = Probe(
      run: ping.run, seq: ping.seq, kind: .pong, origin: label, sentAt: timing.now(),
      peerFetchStartedAt: fetch?.startedAt, peerAppliedAt: fetch?.appliedAt)
    try? await store.writeProbe(pong)
  }

  // MARK: 发起端

  /// 依次探测 `count` 次；每次等 pong 最多 `timeout`。
  public func run(count: Int, appState: String, timeout: Duration = .seconds(30)) async throws -> ProbeReport {
    let run = UUID().uuidString.lowercased()
    var samples: [ProbeSample] = []
    var timeouts = 0
    for seq in 1...max(1, count) {
      let start = timing.now()
      let ping = Probe(run: run, seq: seq, kind: .ping, origin: label, sentAt: start, peerFetchStartedAt: nil, peerAppliedAt: nil)
      try await store.writeProbe(ping)
      guard let pong = await bounded(timeout, { [store] in await Self.pong(in: store, run: run, seq: seq) }) else {
        timeouts += 1
        continue
      }
      samples.append(await sample(seq: seq, start: start, ping: ping, pong: pong, timeout: timeout))
    }
    try await store.deleteProbes(run: run)
    return ProbeReport(label: label, appState: appState, samples: samples, timeouts: timeouts)
  }

  private func sample(seq: Int, start: Date, ping: Probe, pong: Probe, timeout: Duration) async -> ProbeSample {
    let fetch = await bounded(timeout) { [log] in await log.waitForFetch(of: pong.id.uuidString.lowercased()) }
    return Self.sample(
      seq: seq, start: start, end: fetch?.appliedAt ?? timing.now(),
      uploadDone: await log.send(of: ping.id.uuidString.lowercased()),
      peerFetchStarted: pong.peerFetchStartedAt, peerApplied: pong.peerAppliedAt, pongSentAt: pong.sentAt,
      myFetchStarted: fetch?.startedAt)
  }

  /// 把一次往返拆开。发起端的时刻（start/end/uploadDone/myFetchStarted）在同一时钟下，对端的三个时刻在另一个时钟下，
  /// 只在各自内部相减。
  static func sample(
    seq: Int, start: Date, end: Date, uploadDone: Date?, peerFetchStarted: Date?, peerApplied: Date?, pongSentAt: Date,
    myFetchStarted: Date?
  ) -> ProbeSample {
    let rtt = end.timeIntervalSince(start)
    let upload = uploadDone.map { $0.timeIntervalSince(start) }
    let peerPull = peerFetchStarted.flatMap { started in peerApplied.map { $0.timeIntervalSince(started) } }
    let peerProcessing = peerApplied.map { pongSentAt.timeIntervalSince($0) }
    let myPull = myFetchStarted.map { end.timeIntervalSince($0) }
    var remainder: Double?
    if let upload, let peerPull, let peerProcessing, let myPull {
      remainder = Swift.max(0, rtt - upload - peerPull - peerProcessing - myPull)
    }
    return ProbeSample(seq: seq, rtt: rtt, upload: upload, peerPull: peerPull, peerProcessing: peerProcessing, myPull: myPull, remainder: remainder)
  }

  private static func pong(in store: CueStore, run: String, seq: Int) async -> Probe? {
    do {
      for try await probes in store.observe([.probes], { try $0.probes(run: run) }) {
        if let pong = probes.first(where: { $0.kind == .pong && $0.seq == seq }) { return pong }
      }
    } catch {}
    return nil
  }

  /// 工作与超时赛跑：先完成者胜出，超时返回 nil，并取消另一个。
  private func bounded<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
    let timing = timing
    return await withTaskGroup(of: T?.self) { group in
      group.addTask { await work() }
      group.addTask {
        try? await timing.sleep(limit)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }
}
