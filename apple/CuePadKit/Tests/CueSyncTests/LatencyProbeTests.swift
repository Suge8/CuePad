import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 延迟探针：一端写 ping，对端应用后写 pong，回到发起端得到往返时间，并拆成
/// 上传、对端拉取、对端处理、本端拉取和剩余（推送/网络等待）。
@Suite struct LatencyProbeTests {
  let clock = ManualTiming()
  let phone: Rig
  let mac: Rig

  init() throws {
    phone = try Rig(timing: clock)
    mac = try Rig(timing: clock)
  }

  // MARK: 统计

  @Test func distributionUsesNearestRankPercentiles() throws {
    let stats = try #require(Distribution.of((1...10).map(Double.init)))
    #expect(stats.count == 10 && stats.p50 == 5 && stats.p95 == 10 && stats.max == 10)
    let one = try #require(Distribution.of([0.25]))
    #expect(one.p50 == 0.25 && one.p95 == 0.25 && one.max == 0.25)
    #expect(Distribution.of([]) == nil)
  }

  @Test func dominantDelaySeparatesPushWaitFromSlowPull() {
    func sample(upload: Double, peerPull: Double, myPull: Double, remainder: Double) -> ProbeSample {
      ProbeSample(seq: 1, rtt: upload + peerPull + myPull + remainder, upload: upload, peerPull: peerPull, peerProcessing: 0, myPull: myPull, remainder: remainder)
    }
    let pushWait = ProbeReport(label: "a→b", appState: "foreground", samples: [sample(upload: 0.1, peerPull: 0.05, myPull: 0.05, remainder: 4)], timeouts: 0)
    let slowPull = ProbeReport(label: "a→b", appState: "foreground", samples: [sample(upload: 0.1, peerPull: 3, myPull: 2, remainder: 0.4)], timeouts: 0)
    #expect(pushWait.dominantDelay == .pushWait)  // 推送迟迟没到
    #expect(slowPull.dominantDelay == .slowPull)  // 推送到了，拉取慢
  }

  // MARK: 往返

  /// 脚本化的网络：ping 上传 50ms、对端拉取 30ms、对端立即回 pong，pong 网络等待 70ms、本端拉取 20ms。
  @Test(.timeLimit(.minutes(1)))
  func roundTripIsDecomposedIntoUploadPullsAndRemainder() async throws {
    let responder = LatencyProbe(store: mac.store, label: "mac", log: mac.log, timing: clock.timing)
    await responder.startResponding()
    let initiator = LatencyProbe(store: phone.store, label: "phone", log: phone.log, timing: clock.timing)
    let cloud = Loopback(a: phone, b: mac)

    async let report = initiator.run(count: 2, appState: "foreground", timeout: .seconds(30))
    for _ in 0..<2 {
      await phone.queue.waitUntil { saves, _ in !saves.isEmpty }
      clock.advance(.milliseconds(50))  // 上传
      try await cloud.deliverPing(clock: clock, pull: .milliseconds(30))
      await mac.queue.waitUntil { saves, _ in !saves.isEmpty }  // 对端应用后立即写 pong
      clock.advance(.milliseconds(70))  // 网络与推送等待
      try await cloud.deliverPong(clock: clock, pull: .milliseconds(20))
    }
    let result = try await report

    #expect(result.timeouts == 0 && result.samples.count == 2)
    for sample in result.samples {
      #expect(abs(sample.rtt - 0.170) < 1e-6)
      #expect(abs((sample.upload ?? -1) - 0.050) < 1e-6)
      #expect(abs((sample.peerPull ?? -1) - 0.030) < 1e-6)
      #expect(abs((sample.peerProcessing ?? -1) - 0.0) < 1e-6)
      #expect(abs((sample.myPull ?? -1) - 0.020) < 1e-6)
      #expect(abs((sample.remainder ?? -1) - 0.070) < 1e-6)
    }
    #expect(result.rtt?.p50 != nil && abs((result.rtt?.max ?? 0) - 0.170) < 1e-6)
    await responder.stopResponding()
  }

  @Test(.timeLimit(.minutes(1)))
  func withoutAResponderTheProbeTimesOutAndCleansUp() async throws {
    let initiator = LatencyProbe(store: phone.store, label: "phone", log: phone.log, timing: clock.timing)
    async let report = initiator.run(count: 1, appState: "background", timeout: .seconds(5))
    await clock.waitForSleeper()
    clock.advance(.seconds(5))
    let result = try await report

    #expect(result.timeouts == 1 && result.samples.isEmpty && result.appState == "background")
    #expect(try RawDB(phone.fixture.url).count("probes") == 0)  // 探针记录用完即删
  }
}

extension Loopback {
  /// 只递送手机端的 ping 到 Mac：对端拉取开始，经过 `pull` 后应用。
  func deliverPing(clock: ManualTiming, pull: Duration) async throws {
    try await deliverStepped(from: a, to: b, clock: clock, pull: pull)
  }

  func deliverPong(clock: ManualTiming, pull: Duration) async throws {
    try await deliverStepped(from: b, to: a, clock: clock, pull: pull)
  }

  private func deliverStepped(from: Rig, to: Rig, clock: ManualTiming, pull: Duration) async throws {
    var stepped = self
    stepped.beforeApply = { clock.advance(pull) }
    try await stepped.deliver(from: from, to: to)
  }
}
