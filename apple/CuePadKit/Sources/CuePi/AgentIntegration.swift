#if os(macOS)
import CueStore
import Foundation

extension AgentKind {
    /// 可执行文件名
    public var command: String {
        switch self {
        case .pi: "pi"
        case .claudeCode: "claude"
        case .codex: "codex"
        case .opencode: "opencode"
        }
    }
}

public struct PiVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int
    public init(_ major: Int, _ minor: Int, _ patch: Int) { self.major = major; self.minor = minor; self.patch = patch }

    /// 有 `ui_prompt_*` 事件的最低 Pi 版本
    public static let minimumSupported = PiVersion(0, 84, 4)

    /// 从 `pi --version` 的输出里取第一个 `x.y.z`（容忍前缀 `v`）
    init?(parsing output: String) {
        guard let m = output.firstMatch(of: /(\d+)\.(\d+)\.(\d+)/),
              let major = Int(m.1), let minor = Int(m.2), let patch = Int(m.3) else { return nil }
        self.init(major, minor, patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
    public static func < (a: PiVersion, b: PiVersion) -> Bool { (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
}

/// 一个 Agent 在这台 Mac 上的情况，与 CuePad 写给它的文件——唯一的一份状态。
public struct AgentStatus: Sendable, Equatable {
    public enum Presence: Sendable, Equatable {
        case notFound
        /// 只有 Pi 有版本要求
        case tooOld(PiVersion)
        /// 只有 Pi 报版本
        case found(PiVersion?)
    }

    /// CuePad 写给它的文件（Pi 是扩展与技能两样，合起来算）。
    public enum Files: Sendable, Equatable {
        case missing
        case current
        /// 是 CuePad 写的，但与这个版本的 App 要写的不同（旧版、缺一样、App 移动后路径变了）
        case outdated
        /// 同名文件不是 CuePad 写的，不碰
        case foreign
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
    case piTooOld(found: PiVersion)
    /// 同名文件不是 CuePad 写的（参数是它的位置）
    case foreign(String)
    /// Pi 的技能没写上，把扩展还原也失败了：扩展已是新版而技能缺失或旧（原因是两个错误），下次检查会当作旧版重试
    case halfInstalled(reason: String)
}

extension AgentInstallError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let kind): "没有找到 \(kind.name)"
        case .piTooOld(let found): "Pi \(found) 太旧，需要 \(PiVersion.minimumSupported) 或更新"
        case .foreign(let path): "\(path) 是别人的同名文件，没有改动"
        case .halfInstalled(let reason): "扩展装上了，技能没写上，扩展也没能还原：\(reason)。下次启动会再试一次"
        }
    }
}

/// 在哪里找 Agent 的可执行文件，也是给它们的子进程的 PATH（唯一的一处）。GUI 应用的 PATH 很短，所以除了 PATH 还查各家安装脚本的默认位置。
public struct ExecutableLocator: Sendable {
    public var searchDirectories: [URL]
    public init(searchDirectories: [URL]) {
        var unique: [URL] = []
        for directory in searchDirectories where !directory.path.isEmpty && !unique.contains(directory) { unique.append(directory) }
        self.searchDirectories = unique
    }

    /// 本进程的 PATH 加常见安装目录。
    public static var standard: ExecutableLocator { ExecutableLocator(shellPath: ProcessInfo.processInfo.environment["PATH"]) }

    /// 用户登录 shell 的 PATH 在前（Agent 的 bash 看到的是它），再是 `standard`；查不到登录 shell 的就是 `standard`。慢（起一个登录 shell）。
    public static func resolved() async -> ExecutableLocator {
        let login = await loginShellPath()
        return ExecutableLocator(shellPath: [login, ProcessInfo.processInfo.environment["PATH"]].compactMap { $0 }.joined(separator: ":"))
    }

    private init(shellPath: String?) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = (shellPath ?? "").split(separator: ":").map { URL(filePath: String($0), directoryHint: .isDirectory) }
        let common = [home.appending(path: ".local/bin"), URL(filePath: "/opt/homebrew/bin"), URL(filePath: "/usr/local/bin"),
                      home.appending(path: ".bun/bin"), home.appending(path: ".npm-global/bin"), home.appending(path: ".opencode/bin")]
        self.init(searchDirectories: path + common)
    }

    /// 给子进程的 PATH：这组目录，再保底 /usr/bin 与 /bin。
    public var path: String {
        ExecutableLocator(searchDirectories: searchDirectories + [URL(filePath: "/usr/bin"), URL(filePath: "/bin")]).searchDirectories.map(\.path)
            .joined(separator: ":")
    }

    public func candidates(_ command: String) -> [URL] {
        searchDirectories.map { $0.appending(path: command) }.filter { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// 用户登录 shell 的 PATH（交互式启动才会读 .zshrc）；5 秒没结果就放弃。
    public static func loginShellPath() async -> String? {
        let marker = "__CUEPAD_PATH__"
        let shell = URL(filePath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        guard let result = await runCapturing(shell, ["-ilc", "printf '\\n\(marker)%s\\n' \"$PATH\""], timeout: .seconds(5)) else { return nil }
        return result.output.split(separator: "\n").last { $0.hasPrefix(marker) }.map { String($0.dropFirst(marker.count)) }
    }
}

/// CuePad 接入各个 Agent：检测、安装、升级与卸载它们的技能与上报通道（Pi 是桥扩展，Claude Code、Codex 是钩子；OpenCode 直连它的服务，不用装），一起装、一起升级。
/// `status` 没有任何副作用；写入只发生在 `install`，调用方要先征得用户同意；`uninstall` 删掉 CuePad 写的全部文件和因此空出来的目录。
/// 技能只写进每个 Agent 自己的配置目录（`<目录>/skills/cuepad/SKILL.md`），不写几家共用的 `~/.agents/skills`：
/// 那里是用户自己维护的，且会被好几家同时读到。OpenCode 也读 `~/.claude/skills`，两份同名同内容，按名字去重。
public struct AgentIntegration: Sendable {
    private let paths: AgentPaths
    private var pi: PiPaths { paths.pi }
    private let locator: ExecutableLocator
    /// App 里的命令行工具（`Contents/Helpers/cuepad`），技能里写它的绝对路径
    private let cuepad: URL

    public init(paths: AgentPaths = AgentPaths(), locator: ExecutableLocator = .standard, cuepad: URL) {
        self.paths = paths
        self.locator = locator
        self.cuepad = cuepad
    }

    public func home(of kind: AgentKind) -> URL { paths.home(of: kind) }

    /// Claude Code、Codex 的钩子配置（其余没有钩子）。
    private func hooks(_ kind: AgentKind) -> (any AgentHookConfig)? {
        switch kind {
        case .claudeCode: ClaudeCodeHooks(home: home(of: kind))
        case .codex: CodexHooks(home: home(of: kind), locator: locator, environment: paths.environment)
        case .pi, .opencode: nil
        }
    }

    /// 写进钩子配置的命令：App 里 `cuepad` 的绝对路径（App 被移动后它变了，钩子就成了旧版，启动时重写）。
    private func hookCommand(_ kind: AgentKind) -> String { "\(AgentSkill.shellQuoted(cuepad.path)) hook \(kind.rawValue)" }

    /// CuePad 的技能所在的目录（`<配置目录>/skills/cuepad`）。
    public func skillDirectory(of kind: AgentKind) -> URL {
        home(of: kind).appending(path: "skills/\(AgentSkill.name)", directoryHint: .isDirectory)
    }

    private func skillFile(_ kind: AgentKind) -> URL { skillDirectory(of: kind).appending(path: AgentSkill.fileName) }
    private var extensionFile: URL { pi.extensionsDirectory.appending(path: PiExtensionBundle.fileName) }

    @concurrent public func status(of kind: AgentKind) async -> AgentStatus {
        AgentStatus(presence: await presence(of: kind), files: files(of: kind))
    }

    /// 写入（新装或升级）。Agent 不在、Pi 过旧、或同名文件不是 CuePad 写的时拒绝，且什么都不写。
    @concurrent public func install(_ kind: AgentKind) async throws {
        switch await presence(of: kind) {
        case .notFound: throw AgentInstallError.notFound(kind)
        case .tooOld(let version): throw AgentInstallError.piTooOld(found: version)
        case .found: break
        }
        try refuseForeign(kind)
        let skill = skillFile(kind)
        try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard kind == .pi else {
            try Data(AgentSkill.text(for: kind, cuepad: cuepad).utf8).write(to: skill, options: .atomic)
            try await hooks(kind)?.install(command: hookCommand(kind))
            return
        }
        // 两个文件各自原子写入，合起来靠顺序与还原：先把两个目录都建好（建不出来就什么都没写），再写扩展，
        // 技能写不进去时把扩展还原成原来的样子（没有就删掉），不留半升级的状态。
        try FileManager.default.createDirectory(at: pi.extensionsDirectory, withIntermediateDirectories: true)
        let previous = try? Data(contentsOf: extensionFile)
        try Data(PiExtensionBundle.source.utf8).write(to: extensionFile, options: .atomic)
        do {
            try Data(AgentSkill.text(for: kind, cuepad: cuepad).utf8).write(to: skill, options: .atomic)
        } catch {
            do {
                if let previous { try previous.write(to: extensionFile, options: .atomic) } else { try FileManager.default.removeItem(at: extensionFile) }
            } catch let restoreError {
                throw AgentInstallError.halfInstalled(reason: "\(error.localizedDescription)；\(restoreError.localizedDescription)")
            }
            throw error
        }
    }

    /// 删掉 CuePad 写给这个 Agent 的全部文件，以及因此空出来的目录（`skills/cuepad`，空了的 `skills`、`extensions`）。
    /// Agent 已经卸掉了也能删；有别人的同名文件时什么都不删。
    @concurrent public func uninstall(_ kind: AgentKind) async throws {
        try refuseForeign(kind)
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
        await detectPi()?.executable
    }

    private func refuseForeign(_ kind: AgentKind) throws {
        guard files(of: kind) == .foreign else { return }
        let foreign = kind == .pi && (isForeignExtension(read(extensionFile)) || unreadable(extensionFile)) ? extensionFile : skillFile(kind)
        throw AgentInstallError.foreign((foreign.path as NSString).abbreviatingWithTildeInPath)
    }

    private func files(of kind: AgentKind) -> AgentStatus.Files {
        let skill = read(skillFile(kind))
        let skillIsForeign = skill.map { !$0.contains(AgentSkill.ownershipMarker) } ?? unreadable(skillFile(kind))
        let expectedSkill = AgentSkill.text(for: kind, cuepad: cuepad)
        guard kind == .pi else {
            let hooks = hooks(kind)?.files(command: hookCommand(kind))
            if skillIsForeign || hooks == .foreign { return .foreign }
            let skillState: AgentStatus.Files = skill.map { $0 == expectedSkill ? .current : .outdated } ?? .missing
            switch (skillState, hooks ?? skillState) {
            case (.missing, .missing): return .missing
            case (.current, .current): return .current
            default: return .outdated
            }
        }
        let installed = read(extensionFile)
        if isForeignExtension(installed) || unreadable(extensionFile) || skillIsForeign { return .foreign }
        guard let installed else { return .missing }
        return installed == PiExtensionBundle.source && skill == expectedSkill ? .current : .outdated
    }

    private func isForeignExtension(_ text: String?) -> Bool {
        text.map { $0 != PiExtensionBundle.source && !$0.hasPrefix(PiExtensionBundle.ownershipMarker) } ?? false
    }

    private func read(_ file: URL) -> String? {
        (try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// 文件在却读不出或不是 UTF-8 文本：不是 CuePad 写的，不当成缺失去覆盖（不跟随符号链接：失效的链接也算在）。
    private func unreadable(_ file: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil && read(file) == nil
    }

    /// Pi 要报得出够新的版本；其余有可执行文件或配置目录（用过它，含各家的桌面版）就算在。
    private func presence(of kind: AgentKind) async -> AgentStatus.Presence {
        guard kind == .pi else {
            let used = FileManager.default.fileExists(atPath: home(of: kind).path)
            return used || !locator.candidates(kind.command).isEmpty ? .found(nil) : .notFound
        }
        guard let pi = await detectPi() else { return .notFound }
        return pi.version >= .minimumSupported ? .found(pi.version) : .tooOld(pi.version)
    }

    private func detectPi() async -> (executable: URL, version: PiVersion)? {
        let path = locator.path
        for executable in locator.candidates(AgentKind.pi.command) {
            if let output = await Self.capture(executable, ["--version"], path: path), let version = PiVersion(parsing: output) {
                return (executable, version)
            }
        }
        return nil
    }

    /// 运行并取标准输出；超时或无法启动返回 nil。
    private static func capture(_ executable: URL, _ arguments: [String], path: String, timeout: Duration = .seconds(10)) async -> String? {
        let environment = ProcessInfo.processInfo.environment.merging(["PATH": path, "PI_OFFLINE": "1"]) { _, new in new }
        return await runCapturing(executable, arguments, environment: environment, timeout: timeout)?.output
    }
}

/// 随包分发的 Pi 扩展（`Extension/cuepad-bridge.ts`）。文件里的 `EXTENSION_VERSION` 是唯一的版本来源。
public enum PiExtensionBundle {
    static let fileName = "cuepad-bridge.ts"
    /// 扩展文件首行；用它区分"CuePad 写的"与同名的用户文件
    static let ownershipMarker = "// CuePad Pi bridge extension"

    static let source: String = {
        guard let url = Bundle.module.url(forResource: "cuepad-bridge", withExtension: "ts", subdirectory: "Extension"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("bundled cuepad-bridge.ts is missing from the CuePi resource bundle")
        }
        return text
    }()

    public static let version: Int = declaredVersion(in: source) ?? 0

    static func declaredVersion(in source: String) -> Int? {
        source.firstMatch(of: /const EXTENSION_VERSION = (\d+);/).flatMap { Int($0.1) }
    }
}

/// 写给 Agent 的技能：很短，只说 CuePad 是什么、命令在哪，其余让 Agent 看 `--help`（命令行唯一的文档）。
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
            "description: 用户提到 CuePad，要记灵感、看或改任务，或要在手机上看、验收你做的东西（HTML、截图、PDF）时用",
            "---",
            "把文件发到用户手机上的 CuePad：\(command) show <文件>",
            "其余用法（灵感、任务、搜索）看 \(command) --help。",
        ] + (kind == .codex ? ["资料库在沙箱外：写入的命令（show、add、done、move 等）申请在沙箱外运行。"] : [])
        return (["---", "name: \(name)"] + lines + ["\(ownershipMarker)，升级时整文件覆盖 -->", ""]).joined(separator: "\n")
    }

    /// 路径里有空格等字符时 Agent 的 shell 会拆开它。
    static func shellQuoted(_ path: String) -> String {
        path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) } ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif

#if os(macOS)
/// Claude Code、Codex 的钩子配置：CuePad 的条目合并进用户自己的配置文件（别人的条目原样留着），卸载只删 CuePad 的条目。
/// 认 CuePad 的条目只看命令（`<cuepad> hook <agent>`，路径可能是旧位置）。
protocol AgentHookConfig: Sendable {
    /// 没有 CuePad 的条目为 `.missing`；条目齐全、命令就是 `command` 为 `.current`；其余（缺事件、旧路径、没被信任）为 `.outdated`。
    func files(command: String) -> AgentStatus.Files
    func install(command: String) async throws
    func uninstall() async throws
}
#endif
