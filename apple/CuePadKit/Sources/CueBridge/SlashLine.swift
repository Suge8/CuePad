#if os(macOS)
import Foundation

struct SlashLine {
    let name: String
    let argument: String

    init(_ line: String) throws {
        guard line.hasPrefix("/") else { throw BridgeError.rejected("bad_request") }
        let rest = line.dropFirst()
        let name = rest.prefix { !$0.isWhitespace }
        self.name = String(name)
        argument = rest.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
