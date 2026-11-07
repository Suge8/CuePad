import Foundation

/// 交出一句话之前，把它引用、本机还没有的附件取到本机，至迟到 `deadline`：投送执行器与 Cue 等附件只经这里，期限是那句话自己的
/// （投送请求的派发期限 `DeliveryRequest.dispatchDeadline`；对 Cue 说的话从 Mac 开始等起同一段 `DeliveryRequest.phaseLimit`）。
/// 取附件的回调（等附件记录同步过来、再下文件）本身没有时限，所以与期限隔开等（`abandonable`）。
/// 取齐返回 true，到点返回 false；取不来的错误照原样抛出。
public func fetchAttachments(
  _ keys: Set<String>, until deadline: Date, timing: Timing, using fetch: @escaping @Sendable (String) async throws -> Void
) async throws -> Bool {
  guard !keys.isEmpty else { return true }
  return try await withThrowingTaskGroup(of: Bool.self) { group in
    for key in keys { group.addTask { try await abandonable { try await fetch(key) }; return true } }
    group.addTask { try await timing.sleepUntil(deadline); return false }
    defer { group.cancelAll() }
    var remaining = keys.count
    while remaining > 0, let arrived = try await group.next() {
      guard arrived else { return false }
      remaining -= 1
    }
    return true
  }
}
