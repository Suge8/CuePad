#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
@testable import CuePi

extension AgentTape {
    func debug(_ text: String) { debugLine(text, t0: state.withLock { $0.t0 }) }
    func debugLine(_ text: String, t0: Double) {
        guard let filter = ProcessInfo.processInfo.environment["TAPE_DEBUG"], baseName.contains(filter) else { return }
        FileHandle.standardError.write(Data("TAPE \(Int(Date().timeIntervalSince1970 * 1000 - t0)) \(text)\n".utf8))
    }

    /// 钩子信封里 Agent 写给钩子的输入是 base64（`AgentHookEnvelope.input`）：录下时解开成文本（`inputText`），里面的路径、时间才归一得了；回放时再编回去。
    static func envelope(_ line: String, encoded: Bool) -> String {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return line }
        if encoded, let text = object.removeValue(forKey: "inputText") as? String {
            object["input"] = Data(text.utf8).base64EncodedString()
        } else if !encoded, let input = object["input"] as? String, let data = Data(base64Encoded: input), let text = String(data: data, encoding: .utf8) {
            object.removeValue(forKey: "input")
            object["inputText"] = text
        } else {
            return line
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? line
    }

    static func split(_ line: Data) -> (String, String) {
        let text = String(decoding: line, as: UTF8.self)
        guard let space = text.firstIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }

    static func replaceNumber(_ number: Int32, with replacement: String, in text: String) -> String {
        let digits = String(number)
        guard text.contains(digits) else { return text }
        // 前后是字母的不算：进程号也会是哈希、十六进制串里的一段
        return replacing("(?<![0-9A-Za-z])\(digits)(?![0-9A-Za-z])", in: text) { _ in replacement }
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// 测试进程的工作目录（检出的位置因人而异）
    private static let workingDirectory = FileManager.default.currentDirectoryPath
    private static let scratch = (NSTemporaryDirectory() as NSString).standardizingPath
    private static let build = PiProcess.cuepad.deletingLastPathComponent().path
    /// 认得出这台机器与这个人的：主机名、电脑名、git 与 Codex 登录里的邮箱
    static let identity: [(String, String)] = {
        // 主机名大小写因来源而异（ProcessInfo 给小写，gethostname 原样）：两种都换，先长后短
        var buffer = [CChar](repeating: 0, count: 256)
        gethostname(&buffer, buffer.count)
        let hosts = [String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self), ProcessInfo.processInfo.hostName]
        var pairs = (hosts + hosts.compactMap { $0.split(separator: ".").first.map(String.init) }).map { ($0, "localhost") }
        if let name = Host.current().localizedName { pairs.append((name, "Mac")) }
        if let output = try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".gitconfig"), encoding: .utf8),
           let email = output.firstMatch(of: /email\s*=\s*(\S+@\S+)/)?.output.1 {
            pairs.append((String(email), "user@example.com"))
        }
        return pairs.filter { $0.0.count >= 4 }
    }()
    private static let jwt = #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+"#
    static var isoPattern: String { iso }
    static var millisecondsPattern: String { milliseconds }
    static var secondsPattern: String { seconds }
    private static let iso = #"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})"#
    private static let milliseconds = #"(?<![0-9.])1[6-9][0-9]{11}(?![0-9])"#
    private static let seconds = #"(?<![0-9.])1[6-9][0-9]{8}(?![0-9])"#
    private static let placeholder = #"\{(tmp|dtmp|ptmp|pid|ms|s|iso|T|build|fixtures|pwd|home|ext)(?::([^{}"\s]*))?\}"#
    /// 扩展在 hello 里报的随包版本：CuePad 看它与随包版本是否相同决定发不发 `upgrade`，录成占位符，升扩展版本不用重录
    private static let bundledVersion = #""extensionVersion":\#(PiExtensionBundle.version)"#
    private static let window = 2 * 86_400_000.0

    /// 录下前：密钥、路径、pid、时间换成占位符。
    static func normalize(_ text: String, _ state: inout State) -> String {
        var text = text.replacing("\\/", with: "/")
        for secret in state.secrets where text.contains(secret) { text = text.replacing(secret, with: "{secret}") }
        text = replacing(jwt, in: text) { _ in "{secret}" }
        for (value, replacement) in identity where text.contains(value) { text = text.replacing(value, with: replacement) }
        text = text.replacing(bundledVersion, with: #""extensionVersion":{ext}"#)
        let root = state.temporaryRoot, directories = state.temporaryDirectories
        for (form, name) in [(root + "/", "tmp"), (root.replacing("/", with: "-") + "-", "dtmp"), (root.replacing("/", with: "%2F") + "%2F", "ptmp")]
        where text.contains(form) {
            text = replacing(NSRegularExpression.escapedPattern(for: form) + "([0-9]+)(?![0-9])", in: text) { groups in
                directories.firstIndex(of: Int(groups[1] ?? "") ?? -1).map { "{\(name):\($0)}" } ?? groups[0]!
            }
        }
        for (path, name) in [(scratch, "T"), (build, "build"), (fixturesDirectory.path, "fixtures"), (workingDirectory, "pwd"), (home, "home")] where text.contains(path) {
            text = text.replacing(path, with: "{\(name)}")
        }
        for (channel, pid) in state.stubPids { text = replaceNumber(pid, with: "{pid:\(channel)}", in: text) }
        let t0 = state.t0
        text = replacing(iso, in: text) { g in
            let (y, mo, d, h, mi, s, fraction, zone) = (g[1]!, g[2]!, g[3]!, g[4]!, g[5]!, g[6]!, g[7], g[8]!)
            var components = DateComponents(year: Int(y), month: Int(mo), day: Int(d), hour: Int(h), minute: Int(mi), second: Int(s))
            components.timeZone = zone == "Z" ? TimeZone(identifier: "UTC") : TimeZone(secondsFromGMT: (zone.hasPrefix("-") ? -1 : 1)
                * ((Int(zone.dropFirst().prefix(2)) ?? 0) * 3600 + (Int(zone.suffix(2)) ?? 0) * 60))
            guard let date = Calendar(identifier: .gregorian).date(from: components) else { return g[0]! }
            let ms = date.timeIntervalSince1970 * 1000 + (Double("0." + (fraction ?? "0")) ?? 0) * 1000
            guard abs(ms - t0) < window else { return g[0]! }
            return "{iso:\(Int((ms - t0).rounded())):\(fraction?.count ?? 0):\(zone)}"
        }
        text = replacing(milliseconds, in: text) { g in
            let ms = Double(g[0]!) ?? 0
            return abs(ms - t0) < window ? "{ms:\(Int(ms - t0))}" : g[0]!
        }
        text = replacing(seconds, in: text) { g in
            let s = Double(g[0]!) ?? 0
            return abs(s * 1000 - t0) < window ? "{s:\(Int(s - (t0 / 1000).rounded(.down)))}" : g[0]!
        }
        return text
    }

    /// 回放时：占位符换回此刻的值。
    ///
    /// 时刻按回放时钟给：录下的时刻加上回放比录制慢出的那段（`State.lag`）。CuePad 自己的时刻（如托管会话进入工作的 `Date.now`）是真实时钟，
    /// 回放一慢（机器忙），只按 `t0` 加录下的间隔给出的回答时刻就会早于它，"回答落盘"之类的比较永远不成立。这一行里最晚的（不晚于此刻的）
    /// 新时刻落后于此刻就把 `lag` 补上，所以 Agent 刚报出的时刻不早于 CuePad 此前看到的任何事。同一个录下的时刻总给出同一个值（`replayed`），
    /// 录下时相等的（如压缩后退回的计时起点）回放时仍相等。
    static func expand(_ text: String, _ state: inout State) -> String {
        guard text.contains("{") else { return text }
        let root = state.temporaryRoot, directories = state.temporaryDirectories, pids = state.stubPids, t0 = state.t0
        // 晚于此刻的（如额度的重置时刻）不是这一行发生的时刻，不拿来对钟
        let elapsed = Date().timeIntervalSince1970 * 1000 - t0
        let recorded = matches(placeholder, in: text).compactMap { g in recordedDelta(g[1]!, g[2] ?? "", t0: t0) }.filter { $0 <= elapsed }
        if let newest = recorded.max(), newest > state.latest {
            state.latest = newest
            state.lag = max(state.lag, elapsed - newest)
        }
        func at(_ delta: Double) -> Double {
            if let known = state.replayed[delta] { return known }
            let value = t0 + delta + state.lag
            state.replayed[delta] = value
            return value
        }
        return replacing(placeholder, in: text) { g in
            let value = g[2] ?? ""
            switch g[1]! {
            case "tmp", "dtmp", "ptmp":
                guard let index = Int(value), directories.indices.contains(index) else {
                    state.problems.append("回放：录像带里的第 \(value) 个临时目录这次没有建（用例建临时目录的先后变了），重录")
                    return g[0]!
                }
                return switch g[1] {
                case "tmp": "\(root)/\(directories[index])"
                case "dtmp": "\(root.replacing("/", with: "-"))-\(directories[index])"
                default: "\(root.replacing("/", with: "%2F"))%2F\(directories[index])"
                }
            case "T": return scratch
            case "build": return build
            case "fixtures": return fixturesDirectory.path
            case "pwd": return workingDirectory
            case "home": return home
            case "ext": return String(PiExtensionBundle.version)
            case "pid": return pids[value].map { String($0) } ?? g[0]!
            case "ms", "s":
                guard let delta = recordedDelta(g[1]!, value, t0: t0) else { return g[0]! }
                return g[1] == "ms" ? String(Int(at(delta))) : String(Int((at(delta) / 1000).rounded(.down)))
            case "iso":
                let parts = value.split(separator: ":", maxSplits: 2).map(String.init)
                guard parts.count == 3, let delta = Double(parts[0]), let digits = Int(parts[1]) else { return g[0]! }
                return isoString(Date(timeIntervalSince1970: at(delta) / 1000), digits: digits, zone: parts[2])
            default: return g[0]!
            }
        }
    }

    /// 时间占位符录下的时刻，相对 `t0` 的毫秒（`{s:…}` 相对 `t0` 所在的那一秒）；不是时间占位符为 nil。
    private static func recordedDelta(_ kind: String, _ value: String, t0: Double) -> Double? {
        switch kind {
        case "ms": return Double(value)
        case "s": return Double(value).map { ((t0 / 1000).rounded(.down) + $0) * 1000 - t0 }
        case "iso": return value.split(separator: ":", maxSplits: 2).first.flatMap { Double($0) }
        default: return nil
        }
    }

    /// 全部匹配的各组（没匹配上的组为 nil）。
    private static func matches(_ pattern: String, in text: String) -> [[String?]] {
        let regex = try! NSRegularExpression(pattern: pattern)
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? nil : source.substring(with: match.range(at: $0)) }
        }
    }

    /// NSRegularExpression 的替换（Swift Regex 还不支持后行断言）：`transform` 拿到整段与各组（没匹配上的组为 nil）。
    static func replacing(_ pattern: String, in text: String, _ transform: ([String?]) -> String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        let source = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            result += transform((0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? nil : source.substring(with: match.range(at: $0)) })
            last = match.range.location + match.range.length
        }
        return last == 0 ? text : result + source.substring(from: last)
    }

    private static func isoString(_ date: Date, digits: Int, zone: String) -> String {
        let offset = zone == "Z" ? 0 : (zone.hasPrefix("-") ? -1 : 1) * ((Int(zone.dropFirst().prefix(2)) ?? 0) * 3600 + (Int(zone.suffix(2)) ?? 0) * 60)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offset)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        var text = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        if digits > 0 { text += "." + String(String(format: "%09d", c.nanosecond!).prefix(digits)) }
        return text + zone
    }

    static func substitute(_ text: String, _ replay: Replay) -> String {
        var text = text
        for (recorded, actual) in replay.substitutions where text.contains(recorded) { text = text.replacing(recorded, with: actual) }
        guard !replay.ids.isEmpty, var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let id = object["id"] as? Int, let actual = replay.ids[id] else { return text }
        object["id"] = actual
        return (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? text
    }
}
#endif
