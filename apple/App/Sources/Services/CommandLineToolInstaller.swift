#if os(macOS)
import CuePi
import Foundation
import Observation

nonisolated enum CommandLineToolError: Error, Equatable, LocalizedError {
    /// App 包里没有命令行二进制。
    case unavailable
    /// 链接的位置已被别的东西占用，不覆盖。
    case occupied(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "这个 App 里没有命令行工具"
        case .occupied(let path): "\(path) 已经被别的文件或链接占用，没有覆盖；确认不需要后请自行删除再安装"
        }
    }
}

/// 把 App 包内的 `cuepad` 命令行工具装进 PATH：在 `~/.local/bin/cuepad` 建符号链接（不做需要提权的 /usr/local/bin）。
/// 只认自己的链接：位置上是别的东西时不覆盖、不删除。App 换了位置后链接指向旧地方，能检测出来并修复。
@Observable
final class CommandLineToolInstaller {
    enum State: Equatable {
        case unavailable
        case notInstalled
        case installed
        /// 是本 App 的链接，但指向别处（App 被移动或换了副本）；安装即修复。
        case stale
        /// 位置上是别的文件或别人的链接（说明是什么）。
        case blocked(String)
    }

    private(set) var state = State.notInstalled
    /// 用户 shell 的 PATH 里是否有链接所在目录；读不出来为 nil。链接不在 PATH 里，agent 在 bash 里找不到 `cuepad`。
    private(set) var pathIncludesLinkDirectory: Bool?

    let helper: URL
    let linkDirectory: URL
    var link: URL { linkDirectory.appending(path: "cuepad") }
    /// 给人看的链接目录（主目录写成 ~）。
    var linkDirectoryDisplay: String { (linkDirectory.path as NSString).abbreviatingWithTildeInPath }
    /// 让 shell 找得到链接要加进 shell 配置的那一行。
    var pathExport: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directory = linkDirectory.path.hasPrefix(home + "/") ? "$HOME" + linkDirectory.path.dropFirst(home.count) : linkDirectory.path
        return "export PATH=\"\(directory):$PATH\""
    }

    @ObservationIgnored private let shellPath: @Sendable () async -> String?

    init(
        helper: URL = Bundle.main.bundleURL.appending(path: "Contents/Helpers/cuepad"),
        linkDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin", directoryHint: .isDirectory),
        shellPath: @escaping @Sendable () async -> String? = { await ExecutableLocator.loginShellPath() }
    ) {
        self.helper = helper
        self.linkDirectory = linkDirectory
        self.shellPath = shellPath
    }

    func refresh() async {
        state = inspect()
        let directory = linkDirectory.standardizedFileURL.path
        pathIncludesLinkDirectory = await shellPath().map { path in
            path.split(separator: ":").contains { URL(filePath: String($0)).standardizedFileURL.path == directory }
        }
    }

    func install() async throws {
        state = inspect()
        switch state {
        case .unavailable: throw CommandLineToolError.unavailable
        case .installed: return
        case .blocked: throw CommandLineToolError.occupied(link.path)
        case .stale: try FileManager.default.removeItem(at: link)
        case .notInstalled: break
        }
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: helper.path)
        await refresh()
    }

    /// 只删自己的链接（含已失效的）；别人的东西抛错、原样保留。
    func uninstall() async throws {
        state = inspect()
        switch state {
        case .blocked: throw CommandLineToolError.occupied(link.path)
        case .installed, .stale: try FileManager.default.removeItem(at: link)
        case .unavailable, .notInstalled: break
        }
        await refresh()
    }

    private func inspect() -> State {
        let files = FileManager.default
        guard files.isExecutableFile(atPath: helper.path) else { return .unavailable }
        // attributesOfItem 不跟随符号链接：失效的链接也能看到
        guard let type = (try? files.attributesOfItem(atPath: link.path))?[.type] as? FileAttributeType else { return .notInstalled }
        guard type == .typeSymbolicLink, let target = try? files.destinationOfSymbolicLink(atPath: link.path) else {
            return .blocked("已有一个文件")
        }
        if target == helper.path { return .installed }
        return Self.isCuePadHelper(target) ? .stale : .blocked("已有一个指向 \(target) 的链接")
    }

    private static func isCuePadHelper(_ path: String) -> Bool {
        path.hasSuffix(".app/Contents/Helpers/cuepad")
    }
}
#endif
