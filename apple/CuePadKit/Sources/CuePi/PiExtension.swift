#if os(macOS)
import CueStore
import Darwin
import Foundation
import OSLog

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
    /// 没有会话开着旧扩展时不留存根、直接删；有就留到它们都换过来或退出，CuePad 在 Pi 会话上线、下线时复查（`AgentIntegration.retireLegacyPiExtension`）。
    /// 这是一次性的过渡代码：扩展 v39 起的 CuePad 普遍装上后，这几项连同用到它们的地方（`PiBridge.allRun`、hello 里读的扩展版本、`PiExtensionNudge`）一起删；
    /// 之后才从 v37 及更早直接升上来的，旧单文件与目录会被 Pi 一起载入（两份桥），得手动删掉旧文件。
    static let legacyFileName = "cuepad-bridge.ts"
    /// 存根的第二行，各版存根都一样：据此认出存根
    static let legacyStubNote = "// 已改装成同目录下的 cuepad-bridge/。这个空扩展只为让还开着旧单文件扩展的 Pi 会话看到版本变了、歇下时换上新扩展；它们都换过来后 CuePad 删掉它。"
    static let legacyStub = """
        \(ownershipMarker)
        \(legacyStubNote)
        const EXTENSION_VERSION = \(version);
        export default function () {}

        """

    /// 过渡：v38 及更早的扩展不认 `upgrade`，自己用 `fs.watch` 盯着所在的扩展目录，只认自己盯的那个名字（`watchedName`）上的变化，有变化才读磁盘上的版本。
    /// Pi 1.4.0 及更早的官方二进制里是 Bun 1.3，它的 `fs.watch` 把同一毫秒里同类的事件只报第一个、不管名字（Bun 1.4 改成只并完全相同的）；
    /// FSEvents 把一次安装在扩展目录里的几处改动（暂存目录、交换、存根的临时文件与改名）合成一批同时报，旧扩展盯的名字排不到第一个就被吞掉，
    /// 会话一直停在旧版（实测 Pi 1.4.0 上 v37 单文件扩展装后 12 次都没换上）。
    /// 所以还连着这类会话时，CuePad 在扩展目录安静一段后单独碰一下它盯的名字（`PiExtensionNudge`）：自成一批，一定报得出来。
    static let lastDiskWatchingVersion = 38

    /// 这一版扩展盯的名字：v37 及更早盯单文件，v38 盯目录
    static func watchedName(version: Int) -> String { version < lastDiskWatchingVersion ? legacyFileName : directoryName }
}

/// 碰一下 v38 及更早的扩展盯着的名字（只改时间戳，见 `PiExtensionBundle.lastDiskWatchingVersion`），请它读磁盘上的版本：对这类扩展它就是 `upgrade`。
/// 每一下之前先等扩展目录安静 `quiet`，几个名字依次碰，各自成一批。不知道连着的这类会话漏没漏，所以握手时与每次装完都碰；它读到同版本就不动，多碰无害。
@MainActor
final class PiExtensionNudge {
    /// 比 Bun 的 FSEvents 合批时长（0.05 秒）宽出许多：之前的改动早已单独报完，这一下是新一批里的第一个
    static let quiet: Duration = .milliseconds(500)
    private static let log = Logger(subsystem: AppIdentity.id, category: "pi-extension")

    private let extensionsDirectory: URL
    private let timing: Timing
    /// 等着碰的名字，按请求先后
    private var pending: [String] = []
    private var running: Task<Void, Never>?

    init(extensionsDirectory: URL, timing: Timing) {
        self.extensionsDirectory = extensionsDirectory
        self.timing = timing
    }

    /// 碰一下这些扩展版本里自己盯磁盘的那几版盯的名字
    func request(versions: some Sequence<Int>) {
        for name in versions.filter({ $0 <= PiExtensionBundle.lastDiskWatchingVersion }).map(PiExtensionBundle.watchedName) where !pending.contains(name) {
            pending.append(name)
        }
        guard running == nil, !pending.isEmpty else { return }
        running = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        defer { running = nil }
        while let name = pending.first {
            do { try await timing.sleep(Self.quiet) } catch { return }
            pending.removeFirst()
            let path = extensionsDirectory.appending(path: name).path
            if utimes(path, nil) != 0 { Self.log.error("touch \(path, privacy: .public): \(String(cString: strerror(errno)), privacy: .public)") }
        }
    }
}

/// Pi 扩展目录里 CuePad 的那份扩展：整个目录换新（`renamex_np` 交换，在跑的扩展读到的总是完整的一份：v38 及更早盯着扩展目录，之后的在 CuePad 请它核对时读）。
struct PiExtensionFiles: AgentHookConfig {
    let extensionsDirectory: URL
    /// 还有 Pi 会话开着旧单文件扩展（`AgentIntegration.legacyPiExtensionInUse`）
    var legacyInUse: @Sendable () async -> Bool = { false }
    var directory: URL { extensionsDirectory.appending(path: PiExtensionBundle.directoryName, directoryHint: .isDirectory) }
    private var entry: URL { directory.appending(path: PiExtensionBundle.entryName) }
    private var legacyFile: URL { extensionsDirectory.appending(path: PiExtensionBundle.legacyFileName) }

    /// 目录在而入口不是 CuePad 写的：别人的同名目录（参数是它的位置，`~` 缩写）
    var foreign: String? {
        guard FileManager.default.fileExists(atPath: directory.path), !Self.isOurs(entry) else { return nil }
        return (directory.path as NSString).abbreviatingWithTildeInPath
    }

    var writtenFiles: [URL] { [directory] }

    func files(command: String) -> AgentStatus.Files {
        if let foreign { return .foreign(foreign) }
        if !FileManager.default.fileExists(atPath: directory.path) { return Self.isOurs(legacyFile) ? .outdated : .missing }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let same = Set(names) == Set(PiExtensionBundle.files.keys)
            && PiExtensionBundle.files.allSatisfy { Self.read(directory.appending(path: $0.key)) == $0.value }
        return same && !legacyIsBridge ? .current : .outdated
    }

    func install(command: String) async throws {
        let legacyInUse = await legacyInUse()
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
        try retireLegacyFile(inUse: legacyInUse)
    }

    /// 旧路径上还是 CuePad 的单文件桥（不是存根）
    private var legacyIsBridge: Bool {
        Self.isOurs(legacyFile) && Self.read(legacyFile)?.hasPrefix("\(PiExtensionBundle.ownershipMarker)\n\(PiExtensionBundle.legacyStubNote)\n") == false
    }

    /// 旧单文件：有会话还开着旧扩展就换成存根（已是存根的留着），没有就删。只在目录装好之后动：存根一出现旧扩展就可能重新载入，
    /// 那时目录得已经在；没装目录的（没接入）旧文件也不删，免得删掉了却没装上新的。
    func retireLegacyFile(inUse: Bool) throws {
        guard Self.isOurs(legacyFile), Self.isOurs(entry) else { return }
        if !inUse {
            try FileManager.default.removeItem(at: legacyFile)
        } else if legacyIsBridge {
            try Data(PiExtensionBundle.legacyStub.utf8).write(to: legacyFile, options: .atomic)
        }
    }

    /// 扩展目录因此空了一并删掉。
    func uninstall() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        if Self.isOurs(legacyFile) { try fm.removeItem(at: legacyFile) }
        if (try? fm.contentsOfDirectory(atPath: extensionsDirectory.path))?.isEmpty == true { try fm.removeItem(at: extensionsDirectory) }
    }

    private static func isOurs(_ file: URL) -> Bool { read(file)?.hasPrefix(PiExtensionBundle.ownershipMarker) == true }

    private static func read(_ file: URL) -> String? {
        (try? Data(contentsOf: file)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
#endif
