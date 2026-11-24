import CueText
import Foundation

public struct CueChange: Equatable, Sendable {
  public enum Kind: String, Codable, Sendable, CaseIterable {
    case settled
    case waitingForUser
    case failed
    case undelivered
    case done
    case stalled
  }

  public var kind: Kind
  public var task: Card?
  public var leaf: Card?
  public var session: SessionState?
  public var at: Date
  public var seq: Int
  public var detail: String?
  public var recap: Recap?
  public var interrupted = false
  public var tier: CueTier?
}

extension SessionState {
  func reachesCue(_ tier: CueTier) -> Bool {
    switch tier {
    case .yours: false
    case .push: state != .known(.waitingForUser)
    case .full: true
    }
  }

  public func isLeftToYou(_ left: [CueLeft], tiers: [String: CueTier]) -> Bool {
    left.contains { $0.holds(for: self) } || stopsWithYou(CueTier.of(self, chosen: tiers))
  }

  private func stopsWithYou(_ tier: CueTier) -> Bool {
    guard let stop = state.known, Self.leftStops.contains(stop), !reachesCue(tier) else { return false }
    return stop != .settled || answered
  }

  static let leftStops: [WorkState] = [.settled, .error, .interrupted]
}

public struct CueMarks: Codable, Equatable, Sendable {
  public var sessions: Int
  public var tasks: Int
  public var stalls: Date?

  public init(sessions: Int, tasks: Int, stalls: Date? = nil) {
    self.sessions = sessions
    self.tasks = tasks
    self.stalls = stalls
  }

  public init(_ both: Int, stalls: Date? = nil) { self.init(sessions: both, tasks: both, stalls: stalls) }
}

extension SessionState {
  public static let stallAfter: TimeInterval = 20 * 60

  /// 不在等子代理、没有在跑的子代理（只剩 Claude Code 的后台命令，它不报进展），或有在跑的不知道进展时刻，为 nil。
  public var stallsAt: Date? {
    guard runtimeState == .known(.delegating) else { return nil }
    let progress = subagents.filter(\.isRunning).map(\.progressAt)
    guard !progress.isEmpty, !progress.contains(nil) else { return nil }
    return progress.compactMap { $0 }.max()! + Self.stallAfter
  }
}
