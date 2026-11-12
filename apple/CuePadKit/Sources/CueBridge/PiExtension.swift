#if os(macOS)
import Foundation

/// 随包分发的 Pi 扩展（`Extension/cuepad-bridge/`）：托管的 Pi 与探测都用 `--extension` 显式加载这个目录，Pi 载入里面的 `index.ts`。
/// 入口文件里的 `EXTENSION_VERSION` 是唯一的版本来源。
public enum PiExtensionBundle {
    static let directoryName = "cuepad-bridge"

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
#endif
