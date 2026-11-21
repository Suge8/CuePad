import Foundation

public func fetchAttachments(
  _ keys: Set<String>, into files: AttachmentFiles, until due: @escaping @Sendable () async throws -> Void,
  using fetch: @escaping @Sendable (String) async throws -> Void
) async throws -> AttachmentArrival {
  guard !keys.isEmpty else { return .arrived }
  let finished = try await withThrowingTaskGroup(of: Bool.self) { group in
    for key in keys { group.addTask { try await abandonable { try await fetch(key) }; return true } }
    group.addTask { try await due(); return false }
    defer { group.cancelAll() }
    var remaining = keys.count
    while remaining > 0, let arrived = try await group.next() {
      guard arrived else { return false }
      remaining -= 1
    }
    return true
  }
  guard finished else { return .expired }
  return keys.allSatisfy { files.fileURL(for: $0) != nil } ? .arrived : .missing
}

public enum AttachmentArrival: Sendable {
  case arrived
  case expired
  case missing
}
