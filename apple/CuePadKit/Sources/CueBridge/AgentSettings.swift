#if os(macOS)
import Foundation

/// 读各家配置文件里的一两个值（自动压缩的阈值，`AgentFacts.compactsAt`）：读不到、格式不对一律当没配，照这家的缺省。
enum AgentSettings {
    /// JSON 里一条路径上的值；带注释与尾逗号的（OpenCode 的 jsonc）也认。
    static func json(_ url: URL, _ path: String...) -> Any? {
        guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) else { return nil }
        return path.reduce(Optional(root)) { ($0 as? [String: Any])?[$1] }
    }

    /// TOML 里一张表（nil 是顶层）下的一个整数：只认 `键 = 数`，够读阈值这类单值，不为它引一个 TOML 解析库。
    static func tomlInt(_ url: URL, table: String?, key: String) -> Int? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var current: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if current == table, parts.count == 2, parts[0] == key { return Int(parts[1].replacingOccurrences(of: "_", with: "")) }
        }
        return nil
    }
}
#endif
