#if os(macOS)
import CueStore
import Foundation

/// 接入安装与技能文件库共用的目录访问边界：隔离运行不能碰仍指向真实位置的配置与共享目录。
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

    public var touchesShared: Bool {
        !isolated || paths.agentsDirectory.standardizedFileURL != Self.real.agentsDirectory.standardizedFileURL
    }
}
#endif
