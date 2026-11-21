#if os(macOS)
import Foundation

enum AgentSettings {
    /// JSON 里一条路径上的值；带注释与尾逗号的（OpenCode 的 jsonc）也认。
    static func json(_ url: URL, _ path: String...) -> Any? {
        guard let data = try? Data(contentsOf: url), let root = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) else { return nil }
        return path.reduce(Optional(root)) { ($0 as? [String: Any])?[$1] }
    }

    static func tomlInt(_ url: URL, table: String?, key: String) -> Int? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var current: String?
        var closing: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            if let end = closing {
                if raw.contains(end) { closing = nil }
                continue
            }
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = name(line.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")))
                continue
            }
            guard let (left, right) = pair(line) else { continue }
            closing = ["\"\"\"", "'''"].first { right.hasPrefix($0) && !right.dropFirst(3).contains($0) }
            if current == table, left == key { return int(right) }
            guard current == nil, let table else { continue }
            if left == "\(table).\(key)" { return int(right) }
            if left == table, right.hasPrefix("{") {
                let fields = right.trimmingCharacters(in: CharacterSet(charactersIn: "{} ")).split(separator: ",")
                if let found = fields.lazy.compactMap({ pair(String($0)) }).first(where: { $0.0 == key }) { return int(found.1) }
            }
        }
        return nil
    }

    private static func pair(_ line: String) -> (String, String)? {
        let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 ? (name(parts[0]), parts[1]) : nil
    }

    private static func name(_ key: String) -> String {
        key.split(separator: ".").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }.joined(separator: ".")
    }

    private static func int(_ value: String) -> Int? { Int(value.replacingOccurrences(of: "_", with: "")) }
}
#endif
