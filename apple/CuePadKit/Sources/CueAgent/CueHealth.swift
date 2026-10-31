import CueStore
import Foundation

/// Cue 的大脑此刻好不好（本机文件 `<资料库>/Cue/health.json`，不同步）：值班的管理器（`CueKeeper`）每次对完账写，
/// Cue 的工具服务（另一个进程）读给 Cue 看（`setup look`），Mac 的界面也读它。唯一的写者是管理器，事实源是它的内存状态，这里只是投影。
public struct CueHealth: Codable, Equatable, Sendable {
  public enum Phase: String, Codable, Sendable {
    /// 正在起大脑
    case starting
    /// 值班中
    case running
    /// 出了问题，等着自动重起（`nextRetry`）
    case restarting
  }

  public var phase: Phase
  /// 这个班次起来的时刻；没在跑为 nil
  public var shiftStartedAt: Date?
  /// 大脑此刻用的 Agent 与模型（nil 是这家的默认）
  public var runtime: AgentKind?
  public var model: String?
  /// 连续失败了几次（一轮做完清零）
  public var failures: Int
  /// 下一次自动重起的时刻（`restarting` 时有）
  public var nextRetry: Date?
  /// 最近一次出错：几点、原文
  public var lastFailure: Failure?
  /// 最近一次自动换大脑（额度、登录卡住时）：从哪家换到哪家、为什么、几点
  public var failover: Failover?

  public struct Failure: Codable, Equatable, Sendable {
    public var at: Date
    public var text: String
    public init(at: Date, text: String) {
      self.at = at
      self.text = text
    }
  }

  public struct Failover: Codable, Equatable, Sendable {
    public var from: AgentKind
    public var to: AgentKind
    public var reason: String
    public var at: Date
    public init(from: AgentKind, to: AgentKind, reason: String, at: Date) {
      self.from = from
      self.to = to
      self.reason = reason
      self.at = at
    }
  }

  public init(
    phase: Phase, shiftStartedAt: Date? = nil, runtime: AgentKind? = nil, model: String? = nil, failures: Int = 0, nextRetry: Date? = nil,
    lastFailure: Failure? = nil, failover: Failover? = nil
  ) {
    self.phase = phase
    self.shiftStartedAt = shiftStartedAt
    self.runtime = runtime
    self.model = model
    self.failures = failures
    self.nextRetry = nextRetry
    self.lastFailure = lastFailure
    self.failover = failover
  }

  public static func file(in library: URL) -> URL {
    library.appending(path: "Cue", directoryHint: .isDirectory).appending(path: "health.json")
  }

  /// 读不到（还没值过班、不在这台值班）为 nil。
  public static func read(library: URL) -> CueHealth? {
    guard let data = try? Data(contentsOf: file(in: library)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(CueHealth.self, from: data)
  }

  public func write(library: URL) throws {
    let url = Self.file(in: library)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(self).write(to: url, options: .atomic)
  }
}
