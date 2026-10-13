#if os(macOS)
import Foundation

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

/// 随包分发的扩展（`Extension/cuepad-bridge.ts`）。文件里的 `EXTENSION_VERSION` 是唯一的版本来源。
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

/// 随包分发的 skill（`Extension/cuepad-skill.md`，装到 `<skills>/cuepad/SKILL.md`）：告诉 Agent 怎么把文件发到手机、其余用法看 `--help`。
/// 正文里写 `cuepad` 链接的绝对路径（装的时候代入）：不依赖 PATH；App 的位置只在链接里，App 移动后只修链接，skill 不变。
public enum PiSkillBundle {
    static let directoryName = "cuepad"
    static let fileName = "SKILL.md"
    /// 文件末尾的标记行；用它区分"CuePad 写的"与同名的用户文件
    static let ownershipMarker = "<!-- 由 CuePad 写入"

    private static let template: String = {
        guard let url = Bundle.module.url(forResource: "cuepad-skill", withExtension: "md", subdirectory: "Extension"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("bundled cuepad-skill.md is missing from the CuePi resource bundle")
        }
        return text
    }()

    public static func text(cuepad: URL) -> String {
        template.replacingOccurrences(of: "{{cuepad}}", with: shellQuoted(cuepad.path))
    }

    /// 路径里有空格等字符时 Agent 的 shell 会拆开它。
    private static func shellQuoted(_ path: String) -> String {
        path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) } ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum PiInstallation: Sendable, Equatable {
    case notFound
    case found(executable: URL, version: PiVersion)

    public var isSupported: Bool {
        if case .found(_, let version) = self { version >= .minimumSupported } else { false }
    }
}

/// 接入 Pi 写下的三样东西，一起写、一起删。
public enum PiConnectItem: Sendable, CaseIterable {
    /// `<Pi 目录>/extensions/cuepad-bridge.ts`
    case bridgeExtension
    /// `<Pi 目录>/skills/cuepad/SKILL.md`
    case skill
    /// `<链接目录>/cuepad`，指向 App 里的命令行工具
    case commandLink
}

public enum PiItemState: Sendable, Equatable {
    case missing
    case current
    /// 是 CuePad 写的，但不是这个 App 现在要写的样子：旧版扩展或 skill、指向别处（App 移动过）的链接
    case outdated
    /// 位置上是别人的文件或链接
    case foreign
}

/// 接入状态（唯一的一份，全部从磁盘读出）。是否接入以扩展为准：扩展是 CuePad 写的就算已接入，其余两样缺了或旧了是待修复。
public struct PiIntegrationStatus: Sendable, Equatable {
    public var pi: PiInstallation
    public var items: [PiConnectItem: PiItemState]

    public subscript(item: PiConnectItem) -> PiItemState { items[item] ?? .missing }
    public var isConnected: Bool { [.current, .outdated].contains(self[.bridgeExtension]) }
    public var isCurrent: Bool { PiConnectItem.allCases.allSatisfy { self[$0] == .current } }
    /// 被别人的东西占着的位置：有一个就三样都不写
    public var blocked: [PiConnectItem] { PiConnectItem.allCases.filter { self[$0] == .foreign } }
}

public enum PiInstallError: Error, Equatable {
    case piNotFound
    case piTooOld(found: PiVersion)
    /// 这些位置上是别人的东西，没有覆盖
    case occupied([URL])
    /// 写到一半失败，已写的也没能还原（原因是写入与还原的错误）；下次检查会当作待修复重试
    case halfInstalled(reason: String)
}

extension PiInstallError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .piNotFound: "没有找到 pi 命令"
        case .piTooOld(let found): "Pi \(found) 太旧，需要 \(PiVersion.minimumSupported) 或更新"
        case .occupied(let files):
            "\(files.map { ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: "、")) 已经是别的文件，没有覆盖；确认不需要后删掉再接入"
        case .halfInstalled(let reason): "接入写到一半失败，也没能还原：\(reason)。下次启动会再试一次"
        }
    }
}

/// 在哪里找 `pi` 可执行文件。GUI 应用的 PATH 很短，所以除了 PATH 还查常见安装位置。
public struct PiExecutableLocator: Sendable {
    public var searchDirectories: [URL]
    public init(searchDirectories: [URL]) { self.searchDirectories = searchDirectories }

    public static var standard: PiExecutableLocator {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { URL(filePath: String($0), directoryHint: .isDirectory) }
        let common = [home.appending(path: ".local/bin"), URL(filePath: "/opt/homebrew/bin"), URL(filePath: "/usr/local/bin"),
                      home.appending(path: ".bun/bin"), home.appending(path: ".npm-global/bin")]
        return PiExecutableLocator(searchDirectories: path + common)
    }

    var candidates: [URL] {
        searchDirectories.map { $0.appending(path: "pi") }.filter { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// 接入 Pi：检测 Pi，写入与移除扩展、skill 与命令行链接（三样一起）。`status()` 没有任何副作用；写入只在 `install()`，
/// 调用方要先征得用户同意；`uninstall()` 只删 CuePad 写的，别人的同名文件不动。
public struct PiIntegration: Sendable {
    private let paths: PiPaths
    private let locator: PiExecutableLocator
    /// App 里的命令行工具（`Contents/Helpers/cuepad`），链接指向它
    private let helper: URL
    private let shellPath: @Sendable () async -> String?

    public init(
        paths: PiPaths = PiPaths(), locator: PiExecutableLocator = .standard, helper: URL,
        shellPath: @escaping @Sendable () async -> String? = { await PiIntegration.loginShellPath() }
    ) {
        self.paths = paths
        self.locator = locator
        self.helper = helper
        self.shellPath = shellPath
    }

    public func location(of item: PiConnectItem) -> URL {
        switch item {
        case .bridgeExtension: paths.extensionsDirectory.appending(path: PiExtensionBundle.fileName)
        case .skill:
            paths.skillsDirectory.appending(path: PiSkillBundle.directoryName, directoryHint: .isDirectory).appending(path: PiSkillBundle.fileName)
        case .commandLink: paths.binDirectory.appending(path: "cuepad")
        }
    }

    @concurrent public func status() async -> PiIntegrationStatus {
        PiIntegrationStatus(pi: await detectPi(), items: currentItems())
    }

    /// 接入（新装或修复）。Pi 不存在/过旧、或任一位置是别人的东西时拒绝，且什么都不写；写到一半失败时把已写的还原。
    @concurrent public func install() async throws {
        switch await detectPi() {
        case .notFound: throw PiInstallError.piNotFound
        case .found(_, let version) where version < .minimumSupported: throw PiInstallError.piTooOld(found: version)
        case .found: break
        }
        let blocked = PiConnectItem.allCases.filter { currentItems()[$0] == .foreign }
        guard blocked.isEmpty else { throw PiInstallError.occupied(blocked.map(location(of:))) }
        let files = FileManager.default
        for item in PiConnectItem.allCases {
            try files.createDirectory(at: location(of: item).deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var restores: [() throws -> Void] = []
        do {
            restores.append(try replace(.bridgeExtension, with: Data(PiExtensionBundle.source.utf8)))
            restores.append(try replace(.skill, with: Data(PiSkillBundle.text(cuepad: location(of: .commandLink)).utf8)))
            restores.append(try relink())
        } catch {
            var failures: [String] = []
            for restore in restores.reversed() {
                do { try restore() } catch { failures.append(error.localizedDescription) }
            }
            guard failures.isEmpty else { throw PiInstallError.halfInstalled(reason: ([error.localizedDescription] + failures).joined(separator: "；")) }
            throw error
        }
    }

    /// 移除 CuePad 写的那几样（含 skill 留下的空目录）；别人的东西原样保留。
    @concurrent public func uninstall() async throws {
        let files = FileManager.default
        for (item, state) in currentItems() where state == .current || state == .outdated {
            try files.removeItem(at: location(of: item))
        }
        let skillDirectory = location(of: .skill).deletingLastPathComponent()
        if (try? files.contentsOfDirectory(atPath: skillDirectory.path))?.isEmpty == true {
            try files.removeItem(at: skillDirectory)
        }
    }

    /// 用户 shell 的 PATH 里是否有链接所在目录；读不出来为 nil。不在时终端里直接敲 `cuepad` 找不到（Pi 里的 skill 用的是绝对路径，不受影响）。
    @concurrent public func linkDirectoryInShellPath() async -> Bool? {
        let directory = paths.binDirectory.standardizedFileURL.path
        return await shellPath().map { path in
            path.split(separator: ":").contains { URL(filePath: String($0)).standardizedFileURL.path == directory }
        }
    }

    /// 原子写入一个文件，返回把它还原成原样（原来没有就删掉）的动作。
    private func replace(_ item: PiConnectItem, with data: Data) throws -> () throws -> Void {
        let file = location(of: item)
        let previous = try? Data(contentsOf: file)
        try data.write(to: file, options: .atomic)
        return {
            if let previous { try previous.write(to: file, options: .atomic) } else { try FileManager.default.removeItem(at: file) }
        }
    }

    /// 把链接指向这个 App 的命令行工具（原来是 CuePad 指向别处的链接就换掉），返回还原的动作。
    private func relink() throws -> () throws -> Void {
        let link = location(of: .commandLink), files = FileManager.default
        let previous = try? files.destinationOfSymbolicLink(atPath: link.path)
        if previous != nil { try files.removeItem(at: link) }
        try files.createSymbolicLink(atPath: link.path, withDestinationPath: helper.path)
        return {
            try files.removeItem(at: link)
            if let previous { try files.createSymbolicLink(atPath: link.path, withDestinationPath: previous) }
        }
    }

    private func currentItems() -> [PiConnectItem: PiItemState] {
        [.bridgeExtension: extensionState(), .skill: skillState(), .commandLink: linkState()]
    }

    private func extensionState() -> PiItemState {
        let file = location(of: .bridgeExtension)
        guard exists(file) else { return .missing }
        guard let text = read(file) else { return .foreign }
        if text == PiExtensionBundle.source { return .current }
        return text.hasPrefix(PiExtensionBundle.ownershipMarker) ? .outdated : .foreign
    }

    private func skillState() -> PiItemState {
        let file = location(of: .skill)
        guard exists(file) else { return .missing }
        guard let text = read(file), text.contains(PiSkillBundle.ownershipMarker) else { return .foreign }
        return text == PiSkillBundle.text(cuepad: location(of: .commandLink)) ? .current : .outdated
    }

    /// 链接是 CuePad 的：指向的 App 包是 CuePad（看包标识）；App 已被移走、指向的地方不存在时，只认名叫 CuePad.app 的包。
    private func linkState() -> PiItemState {
        let link = location(of: .commandLink)
        guard exists(link) else { return .missing }
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return .foreign }
        if target == helper.path { return .current }
        let suffix = "Contents/Helpers/cuepad"
        guard target.hasSuffix("/" + suffix) else { return .foreign }
        let app = URL(filePath: String(target.dropLast(suffix.count)), directoryHint: .isDirectory)
        if let identifier = Bundle(url: app)?.bundleIdentifier { return identifier == Self.appBundleIdentifier ? .outdated : .foreign }
        return !exists(app) && app.lastPathComponent == "CuePad.app" ? .outdated : .foreign
    }

    static let appBundleIdentifier = "com.sugeh.cuepad"

    /// 不跟随符号链接：失效的链接也算在。
    private func exists(_ file: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: file.path)) != nil
    }

    /// 读不出来或不是 UTF-8 文本为 nil（调用方已确认它在：那就不是 CuePad 写的）。
    private func read(_ file: URL) -> String? {
        (try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// 用户登录 shell 的 PATH（agent 的 bash 看到的是它，而不是 GUI 应用自己那份很短的 PATH）。
    /// 交互式启动才会读 .zshrc；5 秒没结果就放弃。
    @concurrent public static func loginShellPath() async -> String? {
        let marker = "__CUEPAD_PATH__"
        let process = Process()
        process.executableURL = URL(filePath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-ilc", "printf '\\n\(marker)%s\\n' \"$PATH\""]
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard let result = await runCapturing(process, timeout: .seconds(5)) else { return nil }
        return result.output.split(separator: "\n").last { $0.hasPrefix(marker) }.map { String($0.dropFirst(marker.count)) }
    }

    private func detectPi() async -> PiInstallation {
        for executable in locator.candidates {
            let path = locator.searchDirectories.map(\.path).joined(separator: ":")
            if let output = await Self.capture(executable, ["--version"], path: path), let version = PiVersion(parsing: output) {
                return .found(executable: executable, version: version)
            }
        }
        return .notFound
    }

    /// 运行并取标准输出；超时或无法启动返回 nil。
    private static func capture(_ executable: URL, _ arguments: [String], path: String, timeout: Duration = .seconds(10)) async -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": path, "PI_OFFLINE": "1"]) { _, new in new }
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return await runCapturing(process, timeout: timeout)?.output
    }
}
#endif
