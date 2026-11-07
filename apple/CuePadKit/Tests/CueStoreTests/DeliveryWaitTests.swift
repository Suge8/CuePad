@testable import CueStore
import CueText
import Foundation
import Synchronization
import Testing

/// 执行器在旁边等前提时写回给发送方的失败原因：发送方照它显示、可以重发。
@Suite struct DeliveryWaitTests {
  let fixture = try! Fixture()
  var store: CueStore { fixture.store }
  private let pi = SendTarget(kind: .piSession, name: "fix bug", ref: "s1")

  /// 取附件的回调返回了、文件却没落到本机：这一次按失败写回原因，不再见缺就取、空转到期限。
  @Test func 取附件回调返回了文件仍不在_按失败写回原因不空转() async throws {
    let key = AttachmentKey.make(hash: String(repeating: "b", count: 64), format: "png")
    let fetches = Mutex(0)
    let executor = DeliveryExecutor(
      store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }, fetchFile: { _ in fetches.withLock { $0 += 1 } }
    ) { _, _ in .succeeded }
    try await executor.start()
    let made = try await store.requestDelivery("看这张 " + CueFormat.imageMarkup(key: key), to: pi, on: "mac-a")
    try await eventually("写回失败") { try await store.deliveryRequest(made.id)?.status == .known(.failed) }
    #expect(try await store.deliveryRequest(made.id)?.failure == DeliveryPreparation.attachmentMissing.text)
    await quietPeriod(.milliseconds(300))
    #expect(fetches.withLock { $0 } == 1)
    await executor.stop()
  }

  /// 保留了目标、还没开始就到期：原因不把"准备就绪"当成在等什么。
  @Test func 准备就绪后到期_原因不带在等什么() async throws {
    let calls = Mutex(0)
    let executor = DeliveryExecutor(
      store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") },
      preparation: { _ in
        if calls.withLock({ $0 += 1; return $0 }) > 1 { try? await Task.sleep(for: .milliseconds(1500)) }
        return .ready(.existingOnly)
      }
    ) { _, _ in .succeeded }
    let made = try await store.requestDelivery("临界", to: pi, on: "mac-a")
    try RawDB(fixture.url).exec("UPDATE deliveryRequests SET createdAt = createdAt - 599000 WHERE id = '\(made.id.uuidString.lowercased())'")
    try await executor.start()
    try await eventually("到期写回失败") { try await store.deliveryRequest(made.id)?.status == .known(.failed) }
    #expect(try await store.deliveryRequest(made.id)?.failure == "到期仍未派发，没有发出，可以重发")
    await executor.stop()
  }
}
