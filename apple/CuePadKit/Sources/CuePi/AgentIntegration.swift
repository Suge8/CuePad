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
    /// CuePad 要求的最低版本：Pi 要有 `ui_prompt_*` 事件；OpenCode 只认 v2（v1 的服务接口不同，不做兼容）。其余没有要求。
    public var minimumVersion: AgentVersion? {
        switch self {
        case .pi: AgentVersion(0, 84, 4)
        case .opencode: AgentVersion(2, 0, 0)
        case .claudeCode, .codex: nil
        }
    }

    /// 指定它配置目录的环境变量（OpenCode 另认 `XDG_CONFIG_HOME`）；隔离运行没给它时不接入这家（`AgentInstallError.isolated`）。
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
        /// 比 `AgentKind.minimumVersion` 旧
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

    public init(presence: Presence, files: Files) {
        self.presence = presence
        self.files = files
    }

    public var isAvailable: Bool { if case .found = presence { true } else { false } }
    /// CuePad 的文件在（最新或待升级）：接入了。
    public var isConnected: Bool { files == .current || files == .outdated }
    /// 能开新会话：装着、也接入了。开新会话与 Cue 可选的 Agent 都按这一条。
    public var canLaunch: Bool { isAvailable && isConnected }
}

public enum AgentInstallError: Error, Equatable {
    case notFound(AgentKind)
    case tooOld(AgentKind, found: AgentVersion)
    /// 同名文件不是 CuePad 写的（参数是它的位置）
    case foreign(String)
    /// 隔离运行（开发构建）而这家的配置目录是缺省的真实位置：不写，免得把正式版写的条目改成指向开发构建
    case isolated(AgentKind)
}

extension AgentInstallError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let kind): "没有找到 \(kind.name)"
        case .tooOld(let kind, let found): "\(kind.name) \(found) 太旧，需要 \(kind.minimumVersion.map(\.description) ?? "") 或更新"
        case .foreign(let path): "\(path) 是别人的同名文件，没有改动"
        case .isolated(let kind): "开发构建用的隔离资料库：先用 \(kind.homeVariable) 指定 \(kind.name) 的目录再接入"
        }
    }
}

/// CuePad 接入各个 Agent：检测、安装、升级与卸载它们的技能与上报通道（Pi 是桥扩展，Claude Code、Codex 是钩子；OpenCode 直连它的服务，不用装），一起装、一起升级。
/// `status` 没有任何副作用；写入只发生在 `install`，调用方要先征得用户同意；`uninstall` 删掉 CuePad 写的全部文件和因此空出来的目录。
/// 技能只写进每个 Agent 自己的配置目录（`<目录>/skills/cuepad/SKILL.md`），不写几家共用的 `~/.agents/skills`：
/// 那里是用户自己维护的，且会被好几家同时读到。OpenCode 也读 `~/.claude/skills`，两份同名同内容，按名字去重。
/// 写入不做事务：哪一样没写上，状态就是 `outdated`，下次启动的静默升级补上。
public struct AgentIntegration: Sendable {
    let paths: AgentPaths
    private var pi: PiPaths { paths.pi }
    let locate: @Sendable () async -> ExecutableLocator
    /// App 里的命令行工具（`Contents/Helpers/cuepad`），技能里写它的绝对路径
    private let cuepad: URL
    /// 隔离运行（开发构建）：配置目录是缺省真实位置的那几家只检测、不写
    private let isolated: Bool

    public init(
        paths: AgentPaths = AgentPaths(), locate: @escaping @Sendable () async -> ExecutableLocator = { await .system }, cuepad: URL,
        isolated: Bool = false
    ) {
        self.paths = paths
        self.locate = locate
        self.cuepad = cuepad
        self.isolated = isolated
    }

    public func home(of kind: AgentKind) -> URL { paths.home(of: kind) }

    /// 能不能写这家：隔离运行而它的配置目录就是缺省的真实位置（没经环境变量或参数换走）时不能。
    public func isWritable(_ kind: AgentKind) -> Bool {
        !isolated || home(of: kind).standardizedFileURL != AgentPaths(pi: PiPaths(environment: [:]), environment: [:]).home(of: kind).standardizedFileURL
    }

    /// Claude Code、Codex 的钩子配置（其余没有钩子）。
    func hooks(_ kind: AgentKind) -> (any AgentHookConfig)? {
        switch kind {
        case .claudeCode: HookFile.claudeCode(home: home(of: kind), skillDirectory: skillDirectory(of: kind))
        case .codex: CodexHooks(home: home(of: kind), skillDirectory: skillDirectory(of: kind), locate: locate, environment: paths.environment)
        case .pi, .opencode: nil
        }
    }

    /// 写进钩子配置的命令：App 里 `cuepad` 的绝对路径（App 被移动后它变了，钩子就成了旧版，启动时重写）。
    func hookCommand(_ kind: AgentKind) -> String { "\(AgentSkill.shellQuoted(cuepad.path)) hook \(kind.rawValue)" }

    private func skillDirectory(of kind: AgentKind) -> URL {
        home(of: kind).appending(path: "skills/\(AgentSkill.name)", directoryHint: .isDirectory)
    }

    func skillFile(_ kind: AgentKind) -> URL { skillDirectory(of: kind).appending(path: AgentSkill.fileName) }
    private var extensionFile: URL { pi.extensionsDirectory.appending(path: PiExtensionBundle.fileName) }

    /// CuePad 写给这家的文件：技能，Pi 的扩展，钩子配置（只改其中 CuePad 的条目）。界面据此说明会写哪里。
    public func writtenFiles(of kind: AgentKind) -> [URL] {
        [skillFile(kind)] + (kind == .pi ? [extensionFile] : []) + (hooks(kind)?.writtenFiles ?? [])
    }

    @concurrent public func status(of kind: AgentKind) async -> AgentStatus {
        AgentStatus(presence: await detect(kind).presence, files: files(of: kind))
    }

    /// 写入（新装或升级）。隔离运行写不了、Agent 不在或太旧、或同名文件不是 CuePad 写的时拒绝，且什么都不写。
    @concurrent public func install(_ kind: AgentKind) async throws {
        guard isWritable(kind) else { throw AgentInstallError.isolated(kind) }
        switch await detect(kind).presence {
        case .notFound: throw AgentInstallError.notFound(kind)
        case .tooOld(let version): throw AgentInstallError.tooOld(kind, found: version)
        case .found: break
        }
        if case .foreign(let path) = files(of: kind) { throw AgentInstallError.foreign(path) }
        if kind == .pi {
            try FileManager.default.createDirectory(at: pi.extensionsDirectory, withIntermediateDirectories: true)
            try Data(PiExtensionBundle.source.utf8).write(to: extensionFile, options: .atomic)
        }
        try FileManager.default.createDirectory(at: skillDirectory(of: kind), withIntermediateDirectories: true)
        try Data(AgentSkill.text(for: kind, cuepad: cuepad).utf8).write(to: skillFile(kind), options: .atomic)
        try await hooks(kind)?.install(command: hookCommand(kind))
    }

    /// 删掉 CuePad 写给这个 Agent 的全部文件，以及因此空出来的目录（`skills/cuepad`，空了的 `skills`、`extensions`）。
    /// Agent 已经卸掉了也能删；隔离运行写不了、有别人的同名文件时什么都不删。
    @concurrent public func uninstall(_ kind: AgentKind) async throws {
        guard isWritable(kind) else { throw AgentInstallError.isolated(kind) }
        if case .foreign(let path) = files(of: kind) { throw AgentInstallError.foreign(path) }
        try await hooks(kind)?.uninstall()
        var files = [skillFile(kind)]
        if kind == .pi { files.append(extensionFile) }
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        var directories = [skillDirectory(of: kind), skillDirectory(of: kind).deletingLastPathComponent()]
        if kind == .pi { directories.append(pi.extensionsDirectory) }
        for directory in directories where (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// 这台 Mac 上能用的 `pi`（版本够新）；后台托管会话时启动它。
    @concurrent public func locatePi() async -> URL? {
        let found = await detect(.pi)
        guard case .found = found.presence else { return nil }
        return found.executable
    }

    func files(of kind: AgentKind) -> AgentStatus.Files {
        let skill = read(skillFile(kind))
        if skill.map({ !$0.contains(AgentSkill.ownershipMarker) }) ?? unreadable(skillFile(kind)) { return .foreign(abbreviated(skillFile(kind))) }
        let skillState: AgentStatus.Files = skill.map { $0 == AgentSkill.text(for: kind, cuepad: cuepad) ? .current : .outdated } ?? .missing
        let other: AgentStatus.Files
        if kind == .pi {
            let installed = read(extensionFile)
            if installed.map({ $0 != PiExtensionBundle.source && !$0.hasPrefix(PiExtensionBundle.ownershipMarker) }) ?? unreadable(extensionFile) {
                return .foreign(abbreviated(extensionFile))
            }
            other = installed.map { $0 == PiExtensionBundle.source ? .current : .outdated } ?? .missing
        } else {
            other = hooks(kind)?.files(command: hookCommand(kind)) ?? skillState
        }
        switch (skillState, other) {
        case (.missing, .missing): return .missing
        case (.current, .current): return .current
        default: return .outdated
        }
    }

    private func abbreviated(_ file: URL) -> String { (file.path as NSString).abbreviatingWithTildeInPath }

    private func read(_ file: URL) -> String? {
        (try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// 文件在却读不出或不是 UTF-8 文本：不是 CuePad 写的，不当成缺失去覆盖（不跟随符号链接：失效的链接也算在）。
    private func unreadable(_ file: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil && read(file) == nil
    }

    /// 问每家的 `--version`（设置里写出版本）：有版本要求的（Pi、OpenCode）要报得出够新的版本，OpenCode 报的版本太旧是 v1；
    /// 报不出版本的照常算在，只是没有版本。没有可执行文件时，除了 Pi，有配置目录（用过它，含各家的桌面版）也算在。
    func detect(_ kind: AgentKind) async -> (presence: AgentStatus.Presence, executable: URL?) {
        let locator = await locate()
        let used = FileManager.default.fileExists(atPath: home(of: kind).path)
        let candidates = locator.candidates(kind.command)
        for executable in candidates {
            guard let output = await Self.capture(executable, ["--version"], locator: locator),
                  let version = AgentVersion(parsing: output) else { continue }
            let tooOld = kind.minimumVersion.map { version < $0 } ?? false
            return (tooOld ? .tooOld(version) : .found(version), executable)
        }
        if kind.minimumVersion == nil, let executable = candidates.first { return (.found(nil), executable) }
        return (kind != .pi && used ? .found(nil) : .notFound, nil)
    }

    /// 运行并取标准输出；超时或无法启动返回 nil。数据目录给一个用完即删的临时目录：OpenCode 每次运行（`--version` 也是）都往
    /// `$XDG_DATA_HOME/opencode/log` 写日志，不能写进用户的。不运行就读出版本的办法没有通用的：npm 包有 package.json，
    /// Homebrew 与官方脚本装的是裸可执行文件，v2 的里面嵌着版本、v1 的没有同样的标记。
    private static func capture(_ executable: URL, _ arguments: [String], locator: ExecutableLocator, timeout: Duration = .seconds(10)) async -> String? {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "cuepad-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let environment = locator.environment(launching: executable, overrides: ["PI_OFFLINE": "1", "XDG_DATA_HOME": scratch.path])
        return await ChildProcess.run(executable, arguments, environment: environment, timeout: timeout)?.output
    }
}

/// 随包分发的 Pi 扩展（`Extension/cuepad-bridge.ts`）。文件里的 `EXTENSION_VERSION` 是唯一的版本来源。
public enum PiExtensionBundle {
    static let fileName = "cuepad-bridge.ts"
    /// 扩展文件首行；用它区分"CuePad 写的"与同名的用户文件
    static let ownershipMarker = "// CuePad Pi bridge extension"

    /// 随包的那份文件：探测模型时 Pi 直接加载它（`AgentIntegration.available`），不经装到 Pi 扩展目录的那份。
    static let url: URL = {
        guard let url = Bundle.module.url(forResource: "cuepad-bridge", withExtension: "ts", subdirectory: "Extension") else {
            preconditionFailure("bundled cuepad-bridge.ts is missing from the CuePi resource bundle")
        }
        return url
    }()

    static let source: String = {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("bundled cuepad-bridge.ts is unreadable")
        }
        return text
    }()

    public static let version: Int = declaredVersion(in: source) ?? 0

    static func declaredVersion(in source: String) -> Int? {
        source.firstMatch(of: /const EXTENSION_VERSION = (\d+);/).flatMap { Int($0.1) }
    }
}

/// 写给 Agent 的技能：CuePad 是什么、怎么把文件发到手机、做 HTML 页给手机看的约定（只写在这里），其余让 Agent 看 `--help`（命令行唯一的文档）。
/// 正文写 App 里 `cuepad` 的绝对路径，不用先把命令装进 PATH；App 被移动后路径变了，它就成了旧版，启动时重写。
/// Codex 默认在沙箱里跑命令，资料库在沙箱外，写入要申请。
enum AgentSkill {
    static let name = "cuepad"
    static let fileName = "SKILL.md"
    /// 文件末尾的标记行；用它区分"CuePad 写的"与同名的用户文件
    static let ownershipMarker = "<!-- 由 CuePad 写入"

    static func text(for kind: AgentKind, cuepad: URL) -> String {
        let command = shellQuoted(cuepad.path)
        let lines = [
            "description: 要在手机上看或验收你做的东西（网页、截图、PDF、音视频、文稿），或用户提到 CuePad、灵感、任务时用：把文件发到用户手机上的 CuePad，读写其中的灵感与任务。CuePad 是用户记灵感、管任务、指挥 Agent 的 App。",
            "---",
            "CuePad 的手机端看得到这个会话，你发的文件在对话里是一张卡片。",
            "",
            "发到手机：`\(command) show <文件…> [--title 标题]`。一次给几个文件是同一张卡，点开后左右切换。",
            "",
            "做 HTML 页给手机看时：",
            "- 手机顶栏已显示标题：页面里不写标题、页眉、导语和说明页脚，内容直接开始。",
            "- 按手机宽度排版，跟随深浅色（`prefers-color-scheme`）。",
            "- 能用原生控件（`button`、`input`、`select`、`details`）就不自绘。",
            "- 单个文件、不联网：样式与脚本写进同一个 HTML，图片用 `data:` 地址内联。",
            "",
            "其余命令（灵感、任务、搜索）：`\(command) --help`。",
        ] + (kind == .codex ? ["资料库在沙箱外：写入的命令（show、add、done、move 等）申请在沙箱外运行。"] : [])
        return (["---", "name: \(name)"] + lines + ["\(ownershipMarker)，升级时整文件覆盖 -->", ""]).joined(separator: "\n")
    }

    /// 路径里有空格等字符时 Agent 的 shell 会拆开它。
    static func shellQuoted(_ path: String) -> String {
        path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) } ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
