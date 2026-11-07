@testable import CueStore
import Foundation
import Synchronization
import Testing

/// 执行器的期限不被卡住的 handler 拖住：handler 不响应取消只能在这里注入（App 的执行回调都响应取消），所以不从 `Workspace` 走。
@Suite struct DeliveryWaitTests {
  /// 不响应取消的挂起：`release()` 放行。
  final class Hang: Sendable {
    private let continuation = Mutex<UnsafeContinuation<Void, Never>?>(nil)
    private let released = Mutex(false)
    func wait() async {
      await withUnsafeContinuation { (c: UnsafeContinuation<Void, Never>) in
        if released.withLock({ $0 }) { c.resume() } else { continuation.withLock { $0 = c } }
      }
    }
    func release() {
      released.withLock { $0 = true }
      continuation.withLock { $0 }?.resume()
    }
  }

  /// 上一条 handler 卡住、执行队列停着时，这台写给自己的新请求照样锚定派发期限，到期由期限监视写回失败，不一直停在等派发。
  @Test func handler卡住时_写给自己的新请求照样到期写回失败() async throws {
    let clock = ManualTiming()
    let store = try CueStore(location: .isolated(TestLibraries.makeDirectory()), timing: clock.timing)
    let pi = SendTarget(kind: .piSession, name: "fix bug", ref: "s1")
    let hang = Hang()
    let executor = DeliveryExecutor(store: store, hostID: "mac-a", timing: clock.timing, onIssue: { Issue.record("\($0)") }) { request, _ in
      if request.content == "卡住" { await hang.wait() }
      return .succeeded
    }
    try await executor.start()
    let stuck = try await store.requestDelivery("卡住", to: pi, on: "mac-a")
    try await eventually("领取") { try await store.deliveryRequest(stuck.id)?.status == .known(.executing) }
    let later = try await store.requestDelivery("后来的", to: SendTarget(kind: .piSession, name: "b", ref: "s2"), on: "mac-a")
    try await eventually("锚定派发期限") { try await store.deliveryRequest(later.id)?.dispatchDeadline != nil }
    clock.advance(.seconds(DeliveryRequest.phaseLimit + 1))
    try await eventually("到期写回失败") { try await store.deliveryRequest(later.id)?.status == .known(.failed) }
    #expect(try await store.deliveryRequest(later.id)?.failure == "到期仍未派发，没有发出，可以重发")
    hang.release()
    await executor.stop()
  }
}
