#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
@testable import CuePi

/// 输入与录下的比对：UUID 不同记成替换（之后的输出里换成这次的），时间与 JSON-RPC 的请求号不同不算；其余不同返回说明。
enum TapeCompare {
    nonisolated(unsafe) static let uuid = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/

    static func compare(expected: String, actual: String, into replay: inout AgentTape.Replay) -> String? {
        // 启动的工作目录与参数逐项比（参数里可能有键序随机的 JSON）
        if expected.contains("\u{1}") || actual.contains("\u{1}") {
            let e = expected.split(separator: "\u{1}", omittingEmptySubsequences: false), a = actual.split(separator: "\u{1}", omittingEmptySubsequences: false)
            guard e.count == a.count else { return "参数个数不同：\(a.count) 而不是 \(e.count)" }
            for (x, y) in zip(e, a) where x != y {
                if let problem = compare(expected: String(x), actual: String(y), into: &replay) { return problem }
            }
            return nil
        }
        let parse = { (text: String) in try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) }
        guard let e = parse(expected), let a = parse(actual) else { return strings(expected, actual, &replay) }
        return values(e, a, key: nil, &replay)
    }

    private static func values(_ e: Any, _ a: Any, key: String?, _ replay: inout AgentTape.Replay) -> String? {
        switch (e, a) {
        case let (e as [String: Any], a as [String: Any]):
            guard Set(e.keys) == Set(a.keys) else { return "键不同：\(e.keys.sorted()) / \(a.keys.sorted())" }
            for (k, v) in e { if let problem = values(v, a[k]!, key: k, &replay) { return problem } }
            return nil
        case let (e as [Any], a as [Any]):
            guard e.count == a.count else { return "\(key ?? "") 的项数不同" }
            for (x, y) in zip(e, a) { if let problem = values(x, y, key: key, &replay) { return problem } }
            return nil
        case let (e as String, a as String):
            return strings(e, a, &replay)
        case let (e as NSNumber, a as NSNumber):
            if e == a { return nil }
            if key == "id", let x = e as? Int, let y = a as? Int { replay.ids[x] = y; return nil }
            if isTime(e.doubleValue), isTime(a.doubleValue) { return nil }
            return "\(key ?? "") 是 \(a) 而不是 \(e)"
        default:
            return (e as? NSNull != nil && a as? NSNull != nil) ? nil : "\(key ?? "") 的类型不同"
        }
    }

    private static func strings(_ e: String, _ a: String, _ replay: inout AgentTape.Replay) -> String? {
        if e == a { return nil }
        let x = e.matches(of: uuid).map { String($0.output) }, y = a.matches(of: uuid).map { String($0.output) }
        if !x.isEmpty, x.count == y.count, e.replacing(uuid, with: "U") == a.replacing(uuid, with: "U") {
            for (r, n) in zip(x, y) where r != n { replay.substitutions[r] = n }
            return nil
        }
        if timeless(e) == timeless(a) { return nil }  // 只差在此刻的时间
        let same = zip(e, a).prefix { $0 == $1 }.count
        func around(_ text: String) -> String { String(text.dropFirst(max(0, same - 60)).prefix(200)).replacing("\u{1}", with: " ") }
        return "「…\(around(a))」而不是「…\(around(e))」"
    }

    /// 此刻前后两天内的时间（ISO、毫秒、秒）换成同一个记号；别的数字照比
    private static func timeless(_ text: String) -> String {
        var text = AgentTape.replacing(AgentTape.isoPattern, in: text) { _ in "{time}" }
        for pattern in [AgentTape.millisecondsPattern, AgentTape.secondsPattern] {
            text = AgentTape.replacing(pattern, in: text) { groups in
                let value = Double(groups[0] ?? "") ?? 0
                return isTime(value) ? "{time}" : groups[0]!
            }
        }
        return text
    }

    private static func isTime(_ value: Double) -> Bool {
        let now = Date().timeIntervalSince1970
        return abs(value - now) < 2 * 86_400 || abs(value / 1000 - now) < 2 * 86_400
    }
}
#endif
