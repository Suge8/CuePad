#if os(macOS)
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

    /// 文件名 → 内容
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

    /// 过渡（扩展 v38 起装成目录）：v37 及更早是单个文件 `cuepad-bridge.ts`，在跑的旧扩展只盯这个路径上的版本号，读不到就当没升级。
    /// 所以装目录时把它换成同名的空扩展：版本号变了，旧扩展歇下时照常自己重新载入；载入时 Pi 一并载入这个空扩展，它什么都不做，桥只有目录里那一份。
    /// 存根的版本早于随包版本（扩展再升版）时删掉它：那时旧扩展都已换上目录。
    /// 这是一次性的过渡代码：扩展 v39 起的 CuePad 普遍装上（存根随之删掉）后，这几项连同 `PiExtensionFiles` 里用它们的地方一起删；
    /// 之后才从 v37 及更早直接升上来的，旧单文件与目录会被 Pi 一起载入（两份桥），得手动删掉旧文件。
    static let legacyFileName = "cuepad-bridge.ts"
    /// 存根的第二行，各版存根都一样：据此认出存根
    static let legacyStubNote = "// 已改装成同目录下的 cuepad-bridge/。这个空扩展只为让还开着旧单文件扩展的 Pi 会话看到版本变了、歇下时换上新扩展；CuePad 下次升级扩展时删掉它。"
    static let legacyStub = """
        \(ownershipMarker)
        \(legacyStubNote)
        const EXTENSION_VERSION = \(version);
        export default function () {}

        """
}

/// Pi 扩展目录里 CuePad 的那份扩展：整个目录换新（`renamex_np` 交换，在跑的扩展盯着扩展目录，看到的总是完整的一份）。
struct PiExtensionFiles {
    let extensionsDirectory: URL
    var directory: URL { extensionsDirectory.appending(path: PiExtensionBundle.directoryName, directoryHint: .isDirectory) }
    private var entry: URL { directory.appending(path: PiExtensionBundle.entryName) }
    private var legacyFile: URL { extensionsDirectory.appending(path: PiExtensionBundle.legacyFileName) }

    /// 目录在而入口不是 CuePad 写的：别人的同名目录（参数是它的位置，`~` 缩写）
    var foreign: String? {
        guard FileManager.default.fileExists(atPath: directory.path), !Self.isOurs(entry) else { return nil }
        return (directory.path as NSString).abbreviatingWithTildeInPath
    }

    var state: AgentStatus.Files {
        if let foreign { return .foreign(foreign) }
        let legacy = Self.isOurs(legacyFile) ? Self.read(legacyFile) : nil
        if !FileManager.default.fileExists(atPath: directory.path) { return legacy == nil ? .missing : .outdated }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let same = Set(names) == Set(PiExtensionBundle.files.keys)
            && PiExtensionBundle.files.allSatisfy { Self.read(directory.appending(path: $0.key)) == $0.value }
        return same && (legacy == nil || legacy == PiExtensionBundle.legacyStub) ? .current : .outdated
    }

    func install() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
        // 点开头：Pi 不载入，旧扩展也不认这个名字
        let staging = extensionsDirectory.appending(path: ".\(PiExtensionBundle.directoryName)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        for (name, text) in PiExtensionBundle.files {
            try Data(text.utf8).write(to: staging.appending(path: name))
        }
        let flags = fm.fileExists(atPath: directory.path) ? UInt32(RENAME_SWAP) : 0
        guard renamex_np(staging.path, directory.path, flags) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try retireLegacyFile()
    }

    /// 先装好目录再换存根：存根一出现旧扩展就可能重新载入，那时目录得已经在
    private func retireLegacyFile() throws {
        guard Self.isOurs(legacyFile), let legacy = Self.read(legacyFile), legacy != PiExtensionBundle.legacyStub else { return }
        if legacy.hasPrefix("\(PiExtensionBundle.ownershipMarker)\n\(PiExtensionBundle.legacyStubNote)\n") {
            try FileManager.default.removeItem(at: legacyFile)
        } else {
            try Data(PiExtensionBundle.legacyStub.utf8).write(to: legacyFile, options: .atomic)
        }
    }

    func uninstall() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        if Self.isOurs(legacyFile) { try FileManager.default.removeItem(at: legacyFile) }
    }

    private static func isOurs(_ file: URL) -> Bool { read(file)?.hasPrefix(PiExtensionBundle.ownershipMarker) == true }

    private static func read(_ file: URL) -> String? {
        (try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
#endif
