import CloudKit
import CueStore
import Foundation
import Testing

@testable import CueSync

/// 需要真实 iCloud 的联调：默认不运行，签名与容器开通后在已登录 iCloud 的模拟器或设备上用
/// `CUEPAD_ICLOUD_TESTS=1` 启用（宿主进程必须带 iCloud entitlement，命令行 xctest 进程不带）。
/// 两台设备：先在 A 运行 `CUEPAD_ICLOUD_ROLE=writer`，再在 B 运行 `reader`，B 应看到 A 写入的卡片。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CUEPAD_ICLOUD_TESTS"] == "1"))
struct IntegrationTests {
  private static let marker = "cuepad-icloud-integration"

  @Test(.timeLimit(.minutes(3)))
  func recordsWrittenOnOneDeviceAppearOnTheOther() async throws {
    let fixture = try Fixture()
    let sync = CloudSync(store: fixture.store, containerIdentifier: "iCloud.com.sugeh.cuepad", zoneName: "CuePadIntegration")
    try await sync.start()
    defer { Task { await sync.stop() } }

    if ProcessInfo.processInfo.environment["CUEPAD_ICLOUD_ROLE"] == "reader" {
      try await sync.syncNow()
      let found = try await fixture.store.search(SearchQuery(text: Self.marker)).cards
      #expect(!found.isEmpty, "先在另一台设备以 writer 角色运行")
    } else {
      _ = try await fixture.store.createCard(in: nil, body: "\(Self.marker) \(Date())")
      try await sync.syncNow()
      #expect(await sync.status == .idle)
    }
  }
}
