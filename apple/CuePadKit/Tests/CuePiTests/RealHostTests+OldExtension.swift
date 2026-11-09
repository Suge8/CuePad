#if os(macOS)
import Foundation
@testable import CuePi

extension RealHostTests {
    enum OldExtension: CaseIterable, Sendable {
        case unreadable, oldHostedValue

        func rewrite(in installed: URL) throws {
            let file = installed.appending(path: self == .unreadable ? "index.ts" : "lifecycle.ts")
            let source = try String(contentsOf: file, encoding: .utf8)
            let old = switch self {
            case .unreadable: source.replacing(/const EXTENSION_VERSION = \d+;/, with: "const EXTENSION_VERSION = \(PiWire.oldestExtension - 1);")
            case .oldHostedValue: source.replacing(/const IS_HOSTED = .*;/, with: "const IS_HOSTED = process.env[HOSTED_ENV] === \"1\";")
            }
            try old.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
#endif
