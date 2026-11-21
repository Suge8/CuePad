#if os(macOS)
import Foundation

public enum PiExtensionBundle {
    static let directoryName = "cuepad-bridge"

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
