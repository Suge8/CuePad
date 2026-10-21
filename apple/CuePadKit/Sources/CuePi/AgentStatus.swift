#if os(macOS)
import CueStore
import Foundation

/// Agent 报的版本（`--version` 输出里的第一个 `x.y.z`）。
public struct AgentVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int
    public init(_ major: Int, _ minor: Int, _ patch: Int) { self.major = major; self.minor = minor; self.patch = patch }

    /// 从 `--version` 的输出里取第一个 `x.y.z`（容忍前缀 `v`）
    init?(parsing output: String) {
        guard let m = output.firstMatch(of: /(\d+)\.(\d+)\.(\d+)/),
              let major = Int(m.1), let minor = Int(m.2), let patch = Int(m.3) else { return nil }
        self.init(major, minor, patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
    public static func < (a: AgentVersion, b: AgentVersion) -> Bool { (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
}

extension AgentKind {
    /// CuePad 要求的最低版本：Pi 要有 `ui_prompt_*` 事件；OpenCode 只认 v2（v1 的服务接口不同，不做兼容；Homebrew 与官方脚本装的是 v2，
    /// npm 上 v2 是 `@opencode/cli`，旧包 `opencode-ai` 仍是 1.x）。其余没有要求。
    public var minimumVersion: AgentVersion? {
        switch self {
        case .pi: AgentVersion(0, 84, 4)
        case .opencode: AgentVersion(2, 0, 0)
        case .claudeCode, .codex: nil
        }
    }

    /// 指定它配置目录的环境变量（OpenCode 另认 `XDG_CONFIG_HOME`）；不碰真实世界时没给它就不接入这家（`AgentInstallError.isolated`）。
    public var homeVariable: String {
        switch self {
        case .pi: "PI_CODING_AGENT_DIR"
        case .claudeCode: "CLAUDE_CONFIG_DIR"
        case .codex: "CODEX_HOME"
        case .opencode: "OPENCODE_CONFIG_DIR"
        }
    }
}

/// 一个 Agent 在这台 Mac 上的情况，与 CuePad 写给它的文件——唯一的一份状态。
public struct AgentStatus: Sendable, Equatable {
    public enum Presence: Sendable, Equatable {
        case notFound
        case tooOld(AgentVersion)
        /// 有版本要求的报出版本，其余为 nil
        case found(AgentVersion?)
    }

    /// CuePad 写给它的文件（技能，加 Pi 的扩展或钩子配置，合起来算）。
    public enum Files: Sendable, Equatable {
        case missing
        case current
        /// 是 CuePad 写的，但与这个版本的 App 要写的不同（旧版、缺一样、App 移动后路径变了）
        case outdated
        /// 同名文件不是 CuePad 写的，不碰（参数是它的位置，`~` 缩写）
        case foreign(String)
    }

    public var presence: Presence
    public var files: Files
    /// 检测时挑中的可执行文件（`found` 时；只有配置目录、比如只装了桌面版时为 nil）：开会话、起大脑、问模型都用这一个，不另找。
    public var executable: URL?
    /// 没装、而装它要先有的这台还没有（`AgentKind.installPrerequisite`）：先装这个，官方脚本才跑得成。
    public var lacking: InstallPrerequisite?

    public init(presence: Presence, files: Files, executable: URL? = nil, lacking: InstallPrerequisite? = nil) {
        self.presence = presence
        self.files = files
        self.executable = executable
        self.lacking = lacking
    }

    public var isAvailable: Bool { if case .found = presence { true } else { false } }
    /// CuePad 的文件在（最新或待升级）：接入了。
    public var isConnected: Bool { files == .current || files == .outdated }
}

public enum AgentInstallError: Error, Equatable {
    case notFound(AgentKind)
    case tooOld(AgentKind, found: AgentVersion)
    case foreign(String)
    /// 不碰真实世界（装着正式版的 Mac 上的本机构建、测试与验收）而这家的配置目录是缺省的真实位置：不写，免得把正式版写的条目改成指向开发构建
    case isolated(AgentKind)
}

extension AgentInstallError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let kind): "没有找到 \(kind.name)"
        case .tooOld(let kind, let found): "\(kind.name) \(found) 太旧，需要 \(kind.minimumVersion.map(\.description) ?? "") 或更新"
        case .foreign(let path): "\(path) 是别人的同名文件，没有改动"
        case .isolated(let kind): "这台 Mac 装着正式版，本机构建不改它在用的配置：先用 \(kind.homeVariable) 指定 \(kind.name) 的目录再接入"
        }
    }
}
#endif
