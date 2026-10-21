import Foundation

/// 一条同步记录的写入节拍：会话状态（`PiStateContent`）与 Cue 此刻的样子（`CueStateContent`）共用，都由 `PiStateRecorder` 落盘。
/// 每次写入都是一次整条记录的上传与各端的下载，所以：
/// - 与已写入的相同：不写，丢掉挂起的；
/// - 关键变化立即写，取代挂起的：进入或离开工作（工作中→工作中之外的任何一步都算），或 `steady` 变了；
/// - 其余（工作中的细节）合并：离上次写入不到间隔就挂起、到点写最新的一次。
protocol Paced: Equatable, Sendable {
  var isWorking: Bool { get }
  /// 去掉工作中不断变的细节的样子：它变了就是关键变化
  var steady: Self { get }
}

struct Pace<Content: Paced> {
  enum Step {
    case skip
    case now
    /// 挂起：等这么多秒再写（调用方据此起 `timer`）
    case wait(TimeInterval)
  }

  /// 最近一次给的（挂起时到点写的就是它）；还没给过为 nil
  private(set) var content: Content?
  private(set) var written: Content?
  private var writtenAt: Date?
  var timer: Task<Void, Never>?

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

  /// 把 `content` 记为已写入（这一刻），返回它。
  mutating func commit(_ content: Content, at now: Date) -> Content {
    self.content = content
    written = content
    writtenAt = now
    return content
  }

  /// 定时到点：挂起的还在（没被取代、没被取消）就交出要写的。
  mutating func due() -> Content? {
    guard timer != nil, let content else { return nil }
    timer = nil
    return content
  }

  /// 落盘失败：只要之后没有更新的写入，就当作没写过，下一次给的不会被去重跳过。
  mutating func forget(_ content: Content) {
    if written == content { written = nil }
  }

  mutating func cancel() {
    timer?.cancel()
    timer = nil
  }
}
