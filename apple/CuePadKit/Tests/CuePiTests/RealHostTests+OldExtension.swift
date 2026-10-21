#if os(macOS)
import Foundation

extension RealHostTests {
    /// 读不懂托管约定的旧扩展：协议号不同的，与把 `CUEPAD_HOSTED` 当作 "1" 来认的（协议号没变）。
    enum OldExtension: CaseIterable, Sendable {
        case otherProtocol, oldHostedValue

        func rewrite(in installed: URL) throws {
            let file = installed.appending(path: self == .otherProtocol ? "index.ts" : "lifecycle.ts")
            let source = try String(contentsOf: file, encoding: .utf8)
            let old = switch self {
            case .otherProtocol: source.replacing(/const PROTOCOL_VERSION = \d+;/, with: "const PROTOCOL_VERSION = 1;")
            case .oldHostedValue: source.replacing(/const IS_HOSTED = .*;/, with: "const IS_HOSTED = process.env[HOSTED_ENV] === \"1\";")
            }
            try old.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
#endif
