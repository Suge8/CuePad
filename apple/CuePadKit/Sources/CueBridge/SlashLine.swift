#if os(macOS)
import Foundation

/// 斜杠命令的一行：`/名字 参数`，名字到第一个空白为止，其后去掉首尾空白是参数。不以 / 开头抛 `rejected("bad_request")`。
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
