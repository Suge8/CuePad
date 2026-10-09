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
/// 正文里写着 App 里 `cuepad` 的绝对路径（装的时候代入），所以不用先装 PATH 链接就能用；App 被移动后路径变了，它就成了旧版，启动时与扩展一起重写。
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

/// 扩展与 skill 合起来的状态（唯一的一份）：任一个是别人的同名文件就是 `foreign`；没装扩展就是 `missing`（要先征得同意）；
/// 两样都是最新的才是 `current`；其余（旧版、缺 skill、App 移动后路径变了）是 `outdated`，升级时一起写。
public enum PiIntegrationFile: Sendable, Equatable {
    case missing
    case current
    /// 是 CuePad 写的但内容与随包版本不同（含更新、更旧、同版本不同内容）
    case outdated(installed: Int)
    /// 同名文件不是 CuePad 写的
    case foreign
}

public struct PiIntegrationStatus: Sendable, Equatable {
    public var pi: PiInstallation
    public var file: PiIntegrationFile
}

public enum PiInstallError: Error, Equatable {
    case piNotFound
    case piTooOld(found: PiVersion)
    case foreignFile
    /// skill 没写上，把扩展还原也失败了：扩展已是新版而 skill 缺失或旧（原因是两个错误），下次检查会当作旧版重试
    case halfInstalled(reason: String)
}

extension PiInstallError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .piNotFound: "没有找到 pi 命令"
        case .piTooOld(let found): "Pi \(found) 太旧，需要 \(PiVersion.minimumSupported) 或更新"
        case .foreignFile: "Pi 的扩展或技能目录里已有同名的其他文件，没有覆盖"
        case .halfInstalled(let reason): "扩展装上了，技能没写上，扩展也没能还原：\(reason)。下次启动会再试一次"
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

/// CuePad 与 Pi 的集成：检测 Pi，安装与升级扩展和 skill（一起写、一起升级）。`status()` 没有任何副作用；写入只发生在 `install()`，
/// 调用方要先征得用户同意（拒绝时两样都不装）。
public struct PiIntegration: Sendable {
    private let paths: PiPaths
    private let locator: PiExecutableLocator
    /// App 里的命令行工具（`Contents/Helpers/cuepad`），skill 里写它的绝对路径
    private let cuepad: URL

    public init(paths: PiPaths = PiPaths(), locator: PiExecutableLocator = .standard, cuepad: URL) {
        self.paths = paths
        self.locator = locator
        self.cuepad = cuepad
    }

    private var installedFile: URL { paths.extensionsDirectory.appending(path: PiExtensionBundle.fileName) }
    private var skillFile: URL {
        paths.skillsDirectory.appending(path: PiSkillBundle.directoryName, directoryHint: .isDirectory).appending(path: PiSkillBundle.fileName)
    }

    public func status() async -> PiIntegrationStatus {
        PiIntegrationStatus(pi: await detectPi(), file: currentFile())
    }

    /// 写入（新装或升级）。Pi 不存在/过旧、或同名文件不是我们写的时拒绝，且什么都不写。
    public func install() async throws {
        switch await detectPi() {
        case .notFound: throw PiInstallError.piNotFound
        case .found(_, let version) where version < .minimumSupported: throw PiInstallError.piTooOld(found: version)
        case .found: break
        }
        if currentFile() == .foreign { throw PiInstallError.foreignFile }
        // 两个文件各自原子写入，合起来靠顺序与还原：先把两个目录都建好（建不出来就什么都没写），再写扩展，
        // skill 写不进去时把扩展还原成原来的样子（没有就删掉），不留半升级的状态。
        try FileManager.default.createDirectory(at: paths.extensionsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let previous = try? Data(contentsOf: installedFile)
        try Data(PiExtensionBundle.source.utf8).write(to: installedFile, options: .atomic)
        do {
            try Data(PiSkillBundle.text(cuepad: cuepad).utf8).write(to: skillFile, options: .atomic)
        } catch {
            do {
                if let previous { try previous.write(to: installedFile, options: .atomic) } else { try FileManager.default.removeItem(at: installedFile) }
            } catch let restoreError {
                throw PiInstallError.halfInstalled(reason: "\(error.localizedDescription)；\(restoreError.localizedDescription)")
            }
            throw error
        }
    }

    private func currentFile() -> PiIntegrationFile {
        let installed = read(installedFile)
        let skill = read(skillFile)
        let extensionIsForeign = installed.map { $0 != PiExtensionBundle.source && !$0.hasPrefix(PiExtensionBundle.ownershipMarker) } ?? false
        let skillIsForeign = skill.map { !$0.contains(PiSkillBundle.ownershipMarker) } ?? false
        if extensionIsForeign || skillIsForeign { return .foreign }
        guard let installed else { return .missing }
        if installed == PiExtensionBundle.source, skill == PiSkillBundle.text(cuepad: cuepad) { return .current }
        return .outdated(installed: PiExtensionBundle.declaredVersion(in: installed) ?? 0)
    }

    private func read(_ file: URL) -> String? {
        (try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) }
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
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            let watchdog = Task.detached {
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled, process.isRunning { process.terminate() }
            }
            process.terminationHandler = { _ in
                watchdog.cancel()
                continuation.resume(returning: String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
            }
            do { try process.run() } catch { watchdog.cancel(); process.terminationHandler = nil; continuation.resume(returning: nil) }
        }
    }
}
#endif
