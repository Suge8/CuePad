import CueStore
import Foundation

public struct CueHealth: Codable, Equatable, Sendable {
  public enum Phase: String, Codable, Sendable {
    case starting
    case running
    case restarting
  }

  public var phase: Phase
  public var shiftStartedAt: Date?
  public var runtime: AgentKind?
  public var model: String?
  public var failures: Int
  public var nextRetry: Date?
  public var lastFailure: Failure?
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
