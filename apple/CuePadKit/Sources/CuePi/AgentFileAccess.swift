#if os(macOS)
import CueStore
import Foundation

/// 隔离运行不能碰仍指向真实位置的配置与共享目录。
public struct AgentFileAccess: Sendable {
    public let paths: AgentPaths
    private let isolated: Bool
    private static let real = AgentPaths(pi: PiPaths(environment: [:]), environment: [:])

    public init(paths: AgentPaths, isolated: Bool) {
        self.paths = paths
        self.isolated = isolated
    }

    public func touches(_ kind: AgentKind) -> Bool {
        !isolated || paths.home(of: kind).standardizedFileURL != Self.real.home(of: kind).standardizedFileURL
    }

    /// Grok 认字面的 `~/.claude`（不看 CLAUDE_CONFIG_DIR）。环境里没给 HOME（测试只给各家的目录）、或隔离运行时它仍是真实位置，就不碰，返回 nil。
    var grokClaude: URL? {
        guard let home = paths.directory("HOME") else { return nil }
        let directory = home.appending(path: ".claude", directoryHint: .isDirectory)
        return !isolated || directory.standardizedFileURL != Self.real.user(".claude").standardizedFileURL ? directory : nil
    }

    public var touchesShared: Bool {
        !isolated || paths.agentsDirectory.standardizedFileURL != Self.real.agentsDirectory.standardizedFileURL
            && paths.agentsConfigDirectory.standardizedFileURL != Self.real.agentsConfigDirectory.standardizedFileURL
    }
}
#endif
