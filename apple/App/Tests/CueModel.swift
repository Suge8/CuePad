#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import CueText
import Foundation
import Synchronization
import Testing
@testable import CuePad

/// Cue 大脑的剧本，演在共用的假模型上（`server`，CueTestSupport 的 `FakeModel`：Pi 经 Chat Completions 连它）。
/// 有的只演第一次（`once`）：第一次出错、第一次不回（连接挂着，等大脑被杀）。用量固定为 `usage` 个输入 token。
nonisolated final class CueModel: Sendable {
    let server: FakeModel
    private let played = Mutex<[String: Int]>([:])
    private let errorCount = Mutex(0)
    var errors: Int { errorCount.withLock { $0 } }
    private let failingOnce: [String]
    private let asksOnEnable: Bool
    private let finishedAfter = Mutex<[String]>([])
    private let quotaBlocked = Mutex((left: 0, containing: String?.none))
    func blockQuota(times: Int, containing: String? = nil) { quotaBlocked.withLock { $0 = (times, containing) } }
    /// 不回的请求停在这里，直到大脑断开
    private let hang = FakeGate()
    var hanging: Bool { hang.held > 0 }
    /// 先不回、等 `release()` 再回一句话的请求（这一轮停在模型那里，测试趁这时改库）
    private let held = FakeGate()
    var holding: Bool { held.waiting > 0 }
    func release() { for _ in 0..<held.waiting { held.open() } }

    private typealias Reply = FakeReply

    init(usage: Int, failingOnce: [String] = [], asksOnEnable: Bool = false) async throws {
        self.failingOnce = failingOnce
        self.asksOnEnable = asksOnEnable
        server = try await FakeModel(usage: usage)
        server.on({ _ in true }) { [weak self] in self?.script($0) ?? .hang }
    }

    var port: UInt16 { server.port }
    func stop() { server.stop() }

    var requests: [(model: String, effort: String?)] { server.requests.filter { $0.api == .chat }.map { ($0.model, $0.effort) } }

    /// 已就结果含 `fragment` 的工具调用回了这一轮最后一句。
    func answered(_ fragment: String) -> Bool { answers(fragment) > 0 }
    func answers(_ fragment: String) -> Int { finishedAfter.withLock { $0.count { $0.contains(fragment) } } }

    private func once(_ key: String, times: Int = 1) -> Bool {
        played.withLock { played in
            guard played[key, default: 0] < times else { return false }
            played[key, default: 0] += 1
            return true
        }
    }

    private func fail() -> Reply {
        errorCount.withLock { $0 += 1 }
        return .fail("bad things happened")
    }

    private func script(_ fake: FakeRequest) -> Reply {
        let request = fake.json
        func call(_ name: String, _ arguments: [String: any Sendable]) -> Reply { .call(name, arguments) }
        func say(_ text: String) -> Reply { .say(text) }
        // Cue 自己醒来的一轮（刚启用除外）最后的话不写（`CueKeeper.Turn.writesReply`）：要让你看到它醒来看到了什么，就用 tell 对你说
        func tell(_ text: String) -> Reply { call("tell", ["text": text]) }

        let last = (request["messages"] as? [[String: Any]])?.last ?? [:]
        let text: String = switch last["content"] {
        case let string as String: string
        case let parts as [[String: Any]]: parts.compactMap { $0["text"] as? String }.joined()
        default: ""
        }
        let sawImage = (last["content"] as? [[String: Any]] ?? []).contains { $0["type"] as? String == "image_url" }
        if text.contains("暗号是什么") {
            let earlier = (request["messages"] as? [[String: Any]] ?? []).dropLast().map { message -> String in
                switch message["content"] {
                case let string as String: string
                case let parts as [[String: Any]]: parts.compactMap { $0["text"] as? String }.joined()
                default: ""
                }
            }
            if let code = earlier.lazy.compactMap({ $0.firstMatch(of: /暗号是 (\S+)/)?.1 }).last { return say("记得，暗号是 \(code)") }
            // 开了新会话：前面的话不在上下文里，只在这一条输入开头的对话视图里
            if let view = text.firstMatch(of: /<view>[\s\S]*<\/view>/)?.0, let code = view.firstMatch(of: /暗号是 (\S+)/)?.1 { return say("从视图接上：暗号是 \(code)") }
            return say("不记得暗号")
        }
        if last["role"] as? String == "user", text.contains("请等我放行") { return .held(held, then: .say("先这样")) }
        if text.contains("重点有哪些") {
            let messages = request["messages"] as? [[String: Any]] ?? []
            let system = messages.first { $0["role"] as? String == "system" }?["content"] as? String ?? ""
            return say("重点：" + (system.components(separatedBy: "# 重点\n").last ?? ""))
        }
        if text.contains("额度吃紧吗") { return say(text.firstMatch(of: /额度吃紧：\n(- [^\n]*\n)+/).map { String($0.0) } ?? "额度不吃紧") }
        if last["role"] as? String == "tool" {
            if text.contains("建好了"), let id = text.firstMatch(of: /（([0-9a-f]{8})）/)?.1 {
                return call("task", ["action": "start", "task": String(id), "model": "fake/m", "effort": "high"])  // 测试 Mac 上 Pi 报的模型（TestSupport 的 piProbeLine）
            }
            finishedAfter.withLock { $0.append(text) }
            return say("办好了")
        }
        if let answer = text.firstMatch(of: /他回答了「.*」：([^（\n]+)/)?.1 { return say("知道了：\(answer)") }
        if text.contains("请把这张图转给登录页"), let image = text.firstMatch(of: /!\[\]\(cuepad:\/\/file\/[0-9a-f]+(\.[a-z0-9]+)?\)/)?.0 {
            return call("task", ["action": "say", "task": "修好登录页 转图", "text": "看这张\n\(image)"])
        }
        if sawImage { return say("看到图了") }
        if let path = text.firstMatch(of: /附件：图片\.[a-z0-9]+（([^）]+)）/)?.1 { return say("图在 \(path)") }
        if let speech = text.matches(of: /请对隔离会话说「([^」]+)」/).last?.1 {
            return call("task", ["action": "say", "session": "语音停止验收", "text": String(speech)])
        }
        if text.contains("请对登录页说继续") { return call("task", ["action": "say", "task": "修好登录页 说不出去", "text": "继续"]) }
        if let path = text.firstMatch(of: /请读一下关卡 (\S+)/)?.1 { return call("read", ["path": String(path)]) }
        if text.contains("请建个任务并开工") { return call("task", ["action": "add", "title": "修好登录页", "project": "演示", "body": "把登录页修好"]) }
        if text.contains("请问我一个问题") { return call("tell", ["text": "要推送吗？", "ask": "push", "doing": "推送登录页的修复"]) }
        if last["role"] as? String == "user", let key = failingOnce.first(where: text.contains), once("fail:" + key) { return fail() }
        // 额度用完（各家额度类的说法之一，`ErrorSummary` 认作额度）：说了这句的每次都是，`blockQuota` 之后的那几次也是
        let blocked = quotaBlocked.withLock { rule in
            guard rule.left > 0, last["role"] as? String == "user",
                  rule.containing.map(text.contains) ?? true else { return false }
            rule.left -= 1
            return true
        }
        if blocked || last["role"] as? String == "user" && text.contains("请用到额度用完") {
            errorCount.withLock { $0 += 1 }
            return .fail("You have hit your usage limit.")
        }
        if text.contains("请慢慢想"), once("hang") { return .held(hang, then: .say("")) }
        if let block = text.firstMatch(of: /<merge>\n#\d+-\d+ range=([^\n]+)\n/) {
            return call("merge", ["range": String(block.1), "text": "合起来的偏好"])
        }
        if text.contains("三步并行"), let board = text.firstMatch(of: /在做 \d+ 件：\n((?:[ -][^\n]*\n)+)/)?.1 {
            return text.contains("醒来：会话有动静") ? tell("看板：\n" + board) : say("看板：\n" + board)
        }
        if text.contains("醒来：会话有动静"), let failed = text.firstMatch(of: /\n- (\[(?:出错|发送失败)[^\]]*\] [^\n]*)/)?.1 {
            return tell("看到了：\(failed)")
        }
        if text.contains("醒来：会话有动静"), text.contains("半路断开"), once("midway") {
            return call("task", ["action": "say", "task": "修好登录页 半路断开", "text": "继续"])
        }
        if text.contains("醒来：会话有动静"), text.contains("要作答") { return tell("去作答了") }
        if text.contains("醒来：会话有动静"), text.contains("先出两次错"), once("error", times: 2) { return fail() }
        if text.contains("醒来：会话有动静"), text.contains("[等子代理") { return tell("子代理那边停住了") }
        if text.contains("醒来：会话有动静"), text.contains("请收一下") {
            return call("task", ["action": "done", "task": "修好登录页 请收一下", "evidence": ["登录测试全过"]])
        }
        if text.contains("醒来：会话有动静") {
            if text.contains("先出一次错"), once("error") { return fail() }
            if text.contains("只看看") { return say("只是看了看") }
            return tell("登录页那边歇下了")
        }
        if text.contains("醒来：空闲，例行看一眼") { return tell("巡视了一圈") }
        if let fired = text.firstMatch(of: /醒来：定时到点\n- ([^\n]+)/)?.1 { return tell("定时到点：\(fired)") }
        if text.contains("请隔天 9 点清理分支") {
            let at = CueRepeat(.daily, hour: 9, minute: 0)!.next(after: .now).formatted(.iso8601)
            return call("memory", ["action": "remind", "text": "清理过期分支", "at": at, "repeat": "FREQ=DAILY;INTERVAL=2"])
        }
        if text.contains("请每周一 9 点清理分支") {
            let at = CueRepeat(.weekly([2]), hour: 9, minute: 0)!.next(after: .now).formatted(.iso8601)
            return call("memory", ["action": "remind", "text": "清理过期分支", "at": at, "repeat": "FREQ=WEEKLY;BYDAY=MO", "task": "清理过期分支"])
        }
        if text.contains("醒来：刚启用") {
            return asksOnEnable ? call("tell", ["text": "要交给我跟进吗？"]) : say("我看了一眼")
        }
        if text.contains("上一轮出错重试"), text.hasSuffix("</cue>") { return say("接着做上一轮没做完的") }
        return say("收到：" + (text.split(separator: "\n").last.map(String.init) ?? ""))
    }
}

extension CueWake {
    var isSessionActivity: Bool { if case .sessionActivity = self { true } else { false } }
}
#endif
