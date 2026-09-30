import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 真实 iCloud 延迟测量（默认不运行）：`CUEPAD_ICLOUD_TESTS=1`，宿主进程需要 iCloud entitlement。
/// 两端各跑一次：一端 `CUEPAD_ICLOUD_ROLE=responder`（先启动，保持运行到对端结束或超时），
/// 另一端 `CUEPAD_ICLOUD_ROLE=initiator`，可设 `CUEPAD_PROBE_COUNT`（默认 20）与 `CUEPAD_PROBE_STATE`
/// （foreground / background，只是写进报告的标签，实际前后台由你操作设备）。
/// 报告打印分方向的 p50/p95/最大，并说明主要延迟是"推送未到"还是"推送到了但拉取慢"。
/// 反向再对调角色跑一次，即得到另一个方向。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CUEPAD_ICLOUD_TESTS"] == "1"))
struct LatencyProbeIntegrationTests {
  @Test(.timeLimit(.minutes(30)))
  func measureRoundTripsAgainstRealICloud() async throws {
    let environment = ProcessInfo.processInfo.environment
    let fixture = try Fixture()
    let sync = CloudSync(store: fixture.store, containerIdentifier: "iCloud.com.sugeh.cuepad", zoneName: "CuePadProbe")
    try await sync.start()
    defer { Task { await sync.stop() } }

    let role = environment["CUEPAD_ICLOUD_ROLE"] ?? "initiator"
    let probe = LatencyProbe(store: fixture.store, label: role, log: sync.timingLog)
    if role == "responder" {
      await probe.startResponding()
      try await Task.sleep(for: .seconds(25 * 60))
      await probe.stopResponding()
    } else {
      let report = try await probe.run(
        count: Int(environment["CUEPAD_PROBE_COUNT"] ?? "") ?? 20, appState: environment["CUEPAD_PROBE_STATE"] ?? "foreground")
      print(report.description)
      #expect(!report.samples.isEmpty, "全部超时：对端没有在运行，或推送没有到达")
    }
  }
}
