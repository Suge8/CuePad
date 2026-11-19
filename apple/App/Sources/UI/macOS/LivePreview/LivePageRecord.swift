#if os(macOS)
import WebKit

/// 一个活预览里页面自己做了什么，由两段注入脚本送来（`LiveAgentScript`）：控制台与失败的请求、还没回来的请求数、此刻有哪些文档（主框与各个框）。
/// 是单独的对象：`WKUserContentController` 强持有消息的接收方，接收方若是 `LivePreview` 就成了环。
final class LivePageRecord: NSObject, WKScriptMessageHandler {
    struct Entry {
        let level: String
        let text: String
        let source: String?
        /// 动作回执或 `console` 给 Agent 看过了。
        var seen = false

        /// 出处跟在第一行后面，调用栈缩进接在下面。
        var line: String {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            return "[\(level)] \(lines[0])" + (source.map { "（\($0)）" } ?? "") + lines.dropFirst().map { "\n    " + $0 }.joined()
        }
        var isProblem: Bool { ["error", "warn", "network", "dialog"].contains(level) }
    }

    /// 一份文档（主框或框）里的 Agent 脚本：`token` 是那份文档的，文档换了（跳转、重载）就是新的。
    struct Document {
        let info: WKFrameInfo
        let url: String
        let main: Bool
    }

    private(set) var log: [Entry] = []
    /// 主框此刻那份文档；换了就是页面换了。
    private(set) var main: String?
    private(set) var documents: [String: Document] = [:]
    /// 页面里还没回来的 fetch、XHR（页面世界送来，页面自己也能乱报：只拿来等页面安定，等也有上限）。
    private(set) var pending = 0

    /// 记过的条数（含已经挤掉的）：位置用它算，挤掉旧的不挪后来的位置。
    var end: Int { dropped + log.count }
    private var dropped = 0

    func note(_ level: String, _ text: String, source: String? = nil) {
        // 同一句连着来两遍只记一遍（React 开发模式把同一个未捕获的错报两次，出处不同）
        if let last = log.last, last.text == text, last.level == level { return }
        log.append(Entry(level: level, text: text, source: source))
        if log.count > 1_000 {
            log.removeFirst(200)
            dropped += 200
        }
    }

    /// 还没给 Agent 看过的问题（报错、警告、失败的请求、对话框），从位置 `start` 起。
    func unseen(from start: Int = 0) -> [Int] {
        (max(start, dropped)..<end).filter { !log[$0 - dropped].seen && log[$0 - dropped].isProblem }
    }

    func entry(_ position: Int) -> Entry { log[position - dropped] }

    /// 最近 `count` 条的位置。
    func recent(_ count: Int) -> Range<Int> { max(dropped, end - count)..<end }

    func markSeen(_ positions: some Sequence<Int>) {
        for position in positions where position >= dropped && position < end { log[position - dropped].seen = true }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if message.name == Self.agentChannel, let token = body["hello"] as? String {
            let main = body["main"] as? Bool ?? false
            if main {
                // 新文档：上一页的框都跟着没了
                documents = [:]
                self.main = token
                pending = 0
                if let url = body["url"] as? String, url != "about:blank" { note("page", "到了 \(url)") }
            }
            documents[token] = Document(info: message.frameInfo, url: body["url"] as? String ?? "", main: main)
        } else if message.name == Self.logChannel, let level = body["level"] as? String {
            let text = body["text"] as? String ?? ""
            if level == "pending" { return pending = max(0, pending + (Int(text) ?? 0)) }
            let frame = message.frameInfo.isMainFrame ? nil : "框 \(body["page"] as? String ?? "")"
            note(level, text, source: [body["source"] as? String, frame].compactMap(\.self).joined(separator: "，").nonEmpty)
        }
    }

    static let logChannel = "cuepadLog"
    static let agentChannel = "cuepadAgent"
}
#endif
