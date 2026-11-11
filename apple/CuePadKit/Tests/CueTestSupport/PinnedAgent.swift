#if os(macOS)
import Foundation

/// 测试连的真 Agent：`Tests/agents.json` 钉住的版本，由 `xc.sh agents install` 装进专用缓存（`apple/scripts/agents.py`），
/// 不用用户 PATH 上的版本。`bin` 里除了它的命令还有装它的 node：起它时 PATH 只给这个目录与系统目录。
///
/// 没装的家：它的用例跳过，跳过的原因以「未覆盖：」开头（xc.sh 在汇总后列出，不算通过）；
/// 完整矩阵（`CUEPAD_AGENT_MATRIX=full`）时不跳过，`require` 抛错，缺一家就红。
public struct PinnedAgent: Sendable {
  public let name: String
  public let version: String
  public let command: String

  public static let pi = PinnedAgent("pi")
  public static let claude = PinnedAgent("claude")
  public static let codex = PinnedAgent("codex")
  public static let grok = PinnedAgent("grok")
  public static let dsh = PinnedAgent("dsh")
  public static let opencode = PinnedAgent("opencode")

  public static let fullMatrix = ProcessInfo.processInfo.environment["CUEPAD_AGENT_MATRIX"] == "full"

  private struct Entry: Decodable {
    let version: String
    let bin: String
  }

  private static let manifest: [String: Entry] = {
    let file = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "agents.json")
    return (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: file))) ?? [:]
  }()

  private static let cache = ProcessInfo.processInfo.environment["CUEPAD_AGENTS_CACHE"].map { URL(filePath: $0, directoryHint: .isDirectory) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches/cuepad-agents", directoryHint: .isDirectory)

  private init(_ name: String) {
    self.name = name
    version = Self.manifest[name]?.version ?? "?"
    command = Self.manifest[name]?.bin ?? name
  }

  public var bin: URL { Self.cache.appending(path: "\(name)/\(version)/bin", directoryHint: .isDirectory) }
  public var executable: URL { bin.appending(path: command) }
  public var installed: Bool { FileManager.default.isExecutableFile(atPath: executable.path) }

  /// 跳过它的用例时的原因；装了或完整矩阵时为 nil（照跑）
  public var uncovered: String? {
    installed || Self.fullMatrix ? nil : "未覆盖：\(name) \(version)：没装（apple/scripts/xc.sh agents install \(name)）"
  }

  public struct Missing: Error, CustomStringConvertible {
    public let description: String
  }

  /// 起它之前调：没装时抛错（完整矩阵时走到这里）
  public func require() throws {
    guard installed else { throw Missing(description: "完整矩阵缺 \(name) \(version)：apple/scripts/xc.sh agents install \(name)") }
  }

  /// 起它用的环境：不继承跑测试的环境（那里可能有用户的密钥、代理、CuePad 变量），HOME 是给的临时目录，PATH 只有 `bin` 与系统目录。
  public func environment(home: URL, _ extra: [String: String] = [:]) -> [String: String] {
    let base = ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(),
                "LANG": "en_US.UTF-8", "USER": NSUserName(), "SHELL": "/bin/sh", "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost"]
    return base.merging(extra) { $1 }
  }
}
#endif
