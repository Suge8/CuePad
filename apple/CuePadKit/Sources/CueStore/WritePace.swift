import Foundation

/// 一条同步记录的写入节拍：会话状态（`SessionSnapshot`）与 Cue 此刻的样子（`CueStateContent`）共用，都由 `StateRecorder` 落盘。
/// 每次写入都是一次整条记录的上传与各端的下载，所以：
/// - 与已写入的相同：不写，丢掉挂起的；
/// - 关键变化立即写，取代挂起的：进入或离开工作（工作中→工作中之外的任何一步都算），或 `steady` 变了；
/// - 其余（工作中的细节）合并：离上次写入不到间隔就挂起、到点写最新的一次。
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

  /// 定时到点（`id` 是到点的那个计时任务的身份）：挂起的还是它（没被取代、没被取消）才交出要写的；
  /// 旧计时的回调晚到时，位置上已是新装的计时，不能替新的消费。
  mutating func due(_ id: UUID) -> Content? {
    guard timer?.id == id, let content else { return nil }
    timer = nil
    return content
  }

  /// 落盘失败：只要之后没有更新的写入，就当作没写过，下一次给的不会被去重跳过。
  mutating func forget(_ content: Content) {
    if written == content { written = nil }
  }

  mutating func cancel() {
    timer?.task.cancel()
    timer = nil
  }
}
