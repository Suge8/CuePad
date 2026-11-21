import Foundation

protocol Paced: Equatable, Sendable {
  var isWorking: Bool { get }
  var steady: Self { get }
}

struct Pace<Content: Paced> {
  enum Step {
    case skip
    case now
    case wait(TimeInterval)
  }

  private(set) var content: Content?
  private(set) var written: Content?
  private var writtenAt: Date?
  var timer: Owned?

  mutating func offer(_ next: Content, at now: Date, interval: Duration) -> Step {
    let previous = content
    content = next
    guard next != written else {
      cancel()
      return .skip
    }
    let crossesWork = !next.isWorking || !(previous?.isWorking ?? false)
    let changed = written.map { $0.steady != next.steady } ?? true
    let elapsed = writtenAt.map { now.timeIntervalSince($0) } ?? .infinity
    guard !crossesWork, !changed, elapsed < interval.seconds else {
      cancel()
      return .now
    }
    return timer == nil ? .wait(interval.seconds - elapsed) : .skip
  }

  mutating func commit(_ content: Content, at now: Date) -> Content {
    self.content = content
    written = content
    writtenAt = now
    return content
  }

  mutating func due(_ id: UUID) -> Content? {
    guard timer?.id == id, let content else { return nil }
    timer = nil
    return content
  }

  mutating func forget(_ content: Content) {
    if written == content { written = nil }
  }

  mutating func cancel() {
    timer?.task.cancel()
    timer = nil
  }
}
