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

public enum PiInstallation: Sendable, Equatable {
    case notFound
    case found(executable: URL, version: PiVersion)

    public var isSupported: Bool {
        if case .found(_, let version) = self { version >= .minimumSupported } else { false }
    }
}

public enum PiExtensionFile: Sendable, Equatable {
    case missing
    case current
    /// 是 CuePad 写的但内容与随包版本不同（含更新、更旧、同版本不同内容）
    case outdated(installed: Int)
    /// 同名文件不是 CuePad 写的
    case foreign
}

public struct PiExtensionStatus: Sendable, Equatable {
    public var pi: PiInstallation
    public var file: PiExtensionFile
}

public enum PiInstallError: Error, Equatable {
    case piNotFound
    case piTooOld(found: PiVersion)
    case foreignFile
}

extension PiInstallError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .piNotFound: "没有找到 pi 命令"
        case .piTooOld(let found): "Pi \(found) 太旧，需要 \(PiVersion.minimumSupported) 或更新"
        case .foreignFile: "Pi 扩展目录里已有同名的其他文件，没有覆盖"
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

/// 检测 Pi 与扩展状态；安装、升级、卸载扩展。`status()` 没有任何副作用；写入只发生在 `install()`，
/// 调用方要先征得用户同意。
public struct PiExtensionInstaller: Sendable {
    private let paths: PiPaths
    private let locator: PiExecutableLocator

    public init(paths: PiPaths = PiPaths(), locator: PiExecutableLocator = .standard) {
        self.paths = paths
        self.locator = locator
    }

    private var installedFile: URL { paths.extensionsDirectory.appending(path: PiExtensionBundle.fileName) }

    public func status() async -> PiExtensionStatus {
        PiExtensionStatus(pi: await detectPi(), file: currentFile())
    }

    /// 写入（新装或升级）。Pi 不存在/过旧、或同名文件不是我们写的时拒绝，且什么都不写。
    public func install() async throws {
        switch await detectPi() {
        case .notFound: throw PiInstallError.piNotFound
        case .found(_, let version) where version < .minimumSupported: throw PiInstallError.piTooOld(found: version)
        case .found: break
        }
        if currentFile() == .foreign { throw PiInstallError.foreignFile }
        try FileManager.default.createDirectory(at: paths.extensionsDirectory, withIntermediateDirectories: true)
        try Data(PiExtensionBundle.source.utf8).write(to: installedFile, options: .atomic)
    }

    /// 只删 CuePad 写的文件；同名的用户文件保持不动。
    public func uninstall() throws {
        switch currentFile() {
        case .missing, .foreign: return
        case .current, .outdated: try FileManager.default.removeItem(at: installedFile)
        }
    }

    private func currentFile() -> PiExtensionFile {
        guard let data = try? Data(contentsOf: installedFile), let text = String(data: data, encoding: .utf8) else { return .missing }
        if text == PiExtensionBundle.source { return .current }
        guard text.hasPrefix(PiExtensionBundle.ownershipMarker) else { return .foreign }
        return .outdated(installed: PiExtensionBundle.declaredVersion(in: text) ?? 0)
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
