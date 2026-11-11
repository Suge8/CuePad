#if os(macOS)
import Foundation

/// 随包分发的 Pi 扩展（`Extension/cuepad-bridge/`）：托管的 Pi 与探测都用 `--extension` 显式加载这个目录，Pi 载入里面的 `index.ts`。
/// 入口文件里的 `EXTENSION_VERSION` 是唯一的版本来源。
public enum PiExtensionBundle {
    static let directoryName = "cuepad-bridge"
    /// 入口文件首行；迁移时用它区分"旧版 CuePad 装进 Pi 扩展目录的"与同名的用户目录（`PiInstalledExtension`）
    static let ownershipMarker = "// CuePad Pi bridge extension"

    /// App 更新后换成新版的仍是同一路径：在跑的扩展核对的就是它（`SelfReload.check`），重新载入时 Pi 也从它载入。
    static let url: URL = {
        guard let url = Bundle.module.url(forResource: directoryName, withExtension: nil, subdirectory: "Extension") else {
            preconditionFailure("bundled cuepad-bridge/ is missing from the CueBridge resource bundle")
        }
        return url
    }()

    public static let version: Int = {
        guard let entry = try? String(contentsOf: url.appending(path: "index.ts"), encoding: .utf8),
              let version = entry.firstMatch(of: /const EXTENSION_VERSION = (\d+);/).flatMap({ Int($0.1) }) else {
            preconditionFailure("bundled cuepad-bridge/index.ts declares no EXTENSION_VERSION")
        }
        return version
    }()
}

/// 迁移代码，等旧版都升级后删（#202）：旧版 CuePad 把桥扩展装进 Pi 扩展目录（终端里开的 pi 也加载它）。
/// 启动时清掉（`PiRuntime.start`，清不掉下次启动再清），每次托管启动前也清；不能动这个目录（隔离运行碰到真实的 Pi 目录）时托管启动报错。
/// 两份同时加载不能用：两份都读到托管标记、都在同一个 socket 名上 listen，互删对方的临时 socket，旧的那份抛错，整个 Pi 进程随之退出（实测 Pi 1.5.0 + v63）。
/// 只认入口首行是 `ownershipMarker` 的，别人的同名目录不动。
enum PiInstalledExtension {
    static func directory(in extensionsDirectory: URL) -> URL? {
        let directory = extensionsDirectory.appending(path: PiExtensionBundle.directoryName, directoryHint: .isDirectory)
        let entry = (try? Data(contentsOf: directory.appending(path: "index.ts"))).flatMap { String(data: $0, encoding: .utf8) }
        return entry?.hasPrefix(PiExtensionBundle.ownershipMarker) == true ? directory : nil
    }

    static func remove(from extensionsDirectory: URL) throws {
        guard let directory = directory(in: extensionsDirectory) else { return }
        let fm = FileManager.default
        try fm.removeItem(at: directory)
        if (try? fm.contentsOfDirectory(atPath: extensionsDirectory.path))?.isEmpty == true { try fm.removeItem(at: extensionsDirectory) }
    }
}
#endif
