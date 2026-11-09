#if os(macOS)
import CueStore
import Darwin
import Foundation

/// 随包分发的 Pi 扩展（`Extension/cuepad-bridge/`）：装成 Pi 扩展目录下的同名目录，Pi 载入子目录里的 `index.ts`。
/// 入口文件里的 `EXTENSION_VERSION` 是唯一的版本来源。
public enum PiExtensionBundle {
    static let directoryName = "cuepad-bridge"
    static let entryName = "index.ts"
    /// 入口文件首行；用它区分"CuePad 写的"与同名的用户目录
    static let ownershipMarker = "// CuePad Pi bridge extension"

    /// 随包的那个目录：探测模型时 Pi 直接加载它（`AgentIntegration.probe`），不经装到 Pi 扩展目录的那份。
    static let url: URL = {
        guard let url = Bundle.module.url(forResource: directoryName, withExtension: nil, subdirectory: "Extension") else {
            preconditionFailure("bundled cuepad-bridge/ is missing from the CuePi resource bundle")
        }
        return url
    }()

    static let files: [String: String] = {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            preconditionFailure("bundled cuepad-bridge/ is unreadable")
        }
        return Dictionary(uniqueKeysWithValues: names.map { name in
            guard let text = try? String(contentsOf: url.appending(path: name), encoding: .utf8) else {
                preconditionFailure("bundled cuepad-bridge/\(name) is unreadable")
            }
            return (name, text)
        })
    }()

    static var entry: String { files[entryName] ?? "" }

    public static let version: Int = {
        guard let version = entry.firstMatch(of: /const EXTENSION_VERSION = (\d+);/).flatMap({ Int($0.1) }) else {
            preconditionFailure("bundled cuepad-bridge/index.ts declares no EXTENSION_VERSION")
        }
        return version
    }()
}

/// Pi 扩展目录里 CuePad 的那份扩展：整个目录换新（`renamex_np` 交换），在跑的扩展在 CuePad 请它核对时读到的总是完整的一份。
struct PiExtensionFiles: AgentHookConfig {
    let extensionsDirectory: URL
    var directory: URL { extensionsDirectory.appending(path: PiExtensionBundle.directoryName, directoryHint: .isDirectory) }
    private var entry: URL { directory.appending(path: PiExtensionBundle.entryName) }

    /// 目录在而入口不是 CuePad 写的：别人的同名目录（参数是它的位置，`~` 缩写）
    var foreign: String? {
        guard FileManager.default.fileExists(atPath: directory.path), !Self.isOurs(entry) else { return nil }
        return UserHome.shown(directory.path)
    }

    var writtenFiles: [URL] { [directory] }

    func files(command: String) -> AgentStatus.Files {
        if let foreign { return .foreign(foreign) }
        if !FileManager.default.fileExists(atPath: directory.path) { return .missing }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let same = Set(names) == Set(PiExtensionBundle.files.keys)
            && PiExtensionBundle.files.allSatisfy { Self.read(directory.appending(path: $0.key)) == $0.value }
        return same ? .current : .outdated
    }

    func install(command: String) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
        // 点开头：Pi 不载入
        let staging = extensionsDirectory.appending(path: ".\(PiExtensionBundle.directoryName)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        for (name, text) in PiExtensionBundle.files {
            try Data(text.utf8).write(to: staging.appending(path: name))
        }
        let flags = fm.fileExists(atPath: directory.path) ? UInt32(RENAME_SWAP) : 0
        guard renamex_np(staging.path, directory.path, flags) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// 扩展目录因此空了一并删掉。
    func uninstall() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        if (try? fm.contentsOfDirectory(atPath: extensionsDirectory.path))?.isEmpty == true { try fm.removeItem(at: extensionsDirectory) }
    }

    private static func isOurs(_ file: URL) -> Bool { read(file)?.hasPrefix(PiExtensionBundle.ownershipMarker) == true }

    private static func read(_ file: URL) -> String? {
        (try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
#endif
