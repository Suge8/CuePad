#if os(macOS)
import CueStore
import Foundation

public struct AgentVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int
    /// dsh 只发预发布版，按 semver 排在同号正式版之前
    public var prerelease: String?
    public init(_ major: Int, _ minor: Int, _ patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    init?(parsing output: String) {
        guard let m = output.firstMatch(of: /(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?/),
              let major = Int(m.1), let minor = Int(m.2), let patch = Int(m.3) else { return nil }
        self.init(major, minor, patch, prerelease: m.4.map(String.init))
    }

    public var description: String { "\(major).\(minor).\(patch)" + (prerelease.map { "-" + $0 } ?? "") }

    public static func < (a: AgentVersion, b: AgentVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) { return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
        switch (a.prerelease, b.prerelease) {
        case (nil, _): return false
        case (_, nil): return true
        case let (x?, y?): return precedes(x.split(separator: "."), y.split(separator: "."))
        }
    }

    private static func precedes(_ a: [Substring], _ b: [Substring]) -> Bool {
        for (x, y) in zip(a, b) where x != y {
            switch (Int(x), Int(y)) {
            case let (m?, n?): return m < n
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return x < y
            }
        }
        return a.count < b.count
    }
}

/// 状态只有这一份。
public struct AgentStatus: Sendable, Equatable {
    public enum Presence: Sendable, Equatable {
        case notFound
        /// 找到了它的程序，问版本时没有回应（机器很忙、程序卡住）：不知道装没装好，不当成没装
        case unresponsive
        case tooOld(AgentVersion)
        case found(AgentVersion?)
    }

    public enum Files: Sendable, Equatable {
        case missing
        case current
        case outdated
        /// 参数是它的位置，`~` 缩写
        case foreign(String)
    }

    public var presence: Presence
    public var files: Files
    /// 开会话、起大脑、问模型都用这一个，不另找。
    public var executable: URL?
    public var lacking: InstallPrerequisite?

    public init(presence: Presence, files: Files, executable: URL? = nil, lacking: InstallPrerequisite? = nil) {
        self.presence = presence
        self.files = files
        self.executable = executable
        self.lacking = lacking
    }

    public var isAvailable: Bool { if case .found = presence { true } else { false } }
    public var isConnected: Bool { files == .current || files == .outdated }
}

public enum AgentInstallError: Error, Equatable {
    case notFound(AgentKind)
    case unresponsive(AgentKind)
    case tooOld(AgentKind, found: AgentVersion)
    case foreign(String)
    /// 不碰真实世界（装着正式版的 Mac 上的本机构建、测试与验收）而这家的配置目录是缺省的真实位置：不写，免得把正式版写的条目改成指向开发构建
    case isolated(AgentKind)
}

extension AgentInstallError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let kind): String(localized: "没有找到 \(kind.name)")
        case .unresponsive(let kind): String(localized: "\(kind.name) 问版本没有回应，稍后再试")
        case .tooOld(let kind, let found): String(localized: "\(kind.name) \(found.description) 太旧，需要 \(kind.facts.minimumVersion?.description ?? "") 或更新")
        case .foreign(let path): String(localized: "\(path) 是别人的同名文件，没有改动")
        case .isolated(let kind): String(localized: "这台 Mac 装着正式版，本机构建不改它在用的配置：先用 \(kind.facts.homeVariable) 指定 \(kind.name) 的目录再接入")
        }
    }
}
#endif
