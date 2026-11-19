#if os(macOS)
import AppKit
import CueStore
import WebKit

extension LivePreview {

    /// 用户最近 1.5 秒在这个页面上有真实的键鼠输入、或点选开着：等他停手，最多 5 秒。返回等了多久。
    func waitForUser() async throws -> Duration {
        let start = ContinuousClock.now
        while picking || agent.userInput.map({ ContinuousClock.now - $0 < Self.userPause }) == true {
            guard ContinuousClock.now - start < Self.userPatience else { throw LiveRefusal("用户正在操作这个页面，稍后再试") }
            try await Task.sleep(for: .milliseconds(100))
        }
        return ContinuousClock.now - start
    }

    static let userPause = Duration.milliseconds(1_500)
    static let userPatience = Duration.seconds(5)

    /// 页面载出来了、没有弹着等人回答的对话框（弹着时页面的脚本停在那一句上，读、点都会卡住；截图不受影响）。
    func agentReady(allowsAsk: Bool = false) async throws {
        if let ask = asks.first, !allowsAsk {
            throw LiveRefusal("页面弹着 \(ask.kind.shown)「\(ask.message)」在等用户回答：答完之前这一页读不了也点不了，可以 screenshot 看一眼")
        }
        start()
        if phase == .waiting || phase == .stopped { reload() }
        let deadline = ContinuousClock.now + .seconds(10)
        while (web.isLoading || record.main == nil) && phase == .live && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        switch phase {
        case .blank: throw LiveRefusal("这个会话的活预览还没有地址：先 cuepad live <端口或地址>")
        case .waiting, .stopped: throw LiveRefusal("连不上 \(address.map(LiveAddress.shown) ?? "")：服务停了或还没起来。起来之后再运行（不用再 cuepad live）")
        case .idle, .live: break
        }
        guard record.main != nil else { throw LiveRefusal("页面 10 秒还没载出来：过一会儿再试，或 cuepad live screenshot 看一眼") }
    }

    var local: Bool { web.url.map(LiveAddress.isLocal) ?? true }

    func requireLocal() throws {
        guard let url = web.url, !LiveAddress.isLocal(url) else { return }
        throw LiveRefusal("页面到了外网地址 \(url.absoluteString)，不替你操作（snapshot、screenshot、console 还能用；回本机页面用 cuepad live <端口或地址>）")
    }

    /// 此刻这一页读过快照才有；主框换了文档（跳转、重载）就没了。
    func currentPage() -> AgentPage? {
        agent.page.flatMap { $0.main == record.main ? $0 : nil }
    }

    /// 新的一页：换个新代号、从 1 编起。
    func freshPage() -> AgentPage {
        let code = Self.nextCode()
        agent.codes.insert(code)
        return AgentPage(code: code, main: record.main ?? "")
    }

    func target(_ ref: String) throws -> Aim {
        guard let match = ref.wholeMatch(of: /([a-z]+)(\d+)/), let n = Int(match.2) else {
            throw LiveRefusal("「\(ref)」不是引用：引用是快照里 [ref=…] 的值，如 a5")
        }
        let code = String(match.1)
        guard let page = currentPage(), code == page.code else {
            if agent.codes.contains(code) {
                throw LiveRefusal("引用 \(ref) 是之前那一页的（页面跳转或重载过）：重新 cuepad live snapshot")
            }
            throw LiveRefusal("引用 \(ref) 不是这一页的：先 cuepad live snapshot 拿这一页的引用")
        }
        guard let token = page.owners[n], let document = record.documents[token] else {
            throw LiveRefusal("这一页没有引用 \(ref)（编号只到 \(page.code)\(page.next)）：重新 cuepad live snapshot")
        }
        if !document.main, let url = URL(string: document.url), !LiveAddress.isLocal(url) {
            throw LiveRefusal("\(ref) 在外网来源 \(Self.origin(document.url)) 的框里，不替你操作")
        }
        return Aim(ref: ref, n: n, document: document, token: token)
    }

    /// 页面代号 a、b … z、aa、ab …：全 App 一串，从随机一处起，App 重开后旧引用撞上新代号的机会也小（撞上了还得这个预览发过它，`target`）。
    private static func nextCode() -> String {
        codeCounter += 1
        var n = codeCounter, code = ""
        while n > 0 {
            n -= 1
            code = String(UnicodeScalar(UInt8(97 + n % 26))) + code
            n /= 26
        }
        return code
    }

    private static var codeCounter = Int.random(in: 0..<26)

    // MARK: 调脚本

    /// 在那份文档的 Agent 脚本里跑一段（`LiveAgentScript.agent`）；页面自己的脚本卡住（死循环、弹着对话框）时到点报错，不陪它一直等。
    /// `stopsOnAsk`：这一下可能让页面弹对话框（点击）：弹了就不再等它（脚本停在那一句上要等用户回答），抛 `AskPending`。
    /// `stopsOnLeave`：等的时候页面开始换文档就不再等（旧文档里的 Promise 不会再回来），抛 `PageLeft`。
    func call(
        _ body: String, _ arguments: [String: Any] = [:], in document: LivePageRecord.Document, within limit: Duration = .seconds(10), stopsOnAsk: Bool = false,
        stopsOnLeave: Bool = false
    ) async throws -> [String: Any] {
        let info = document.info
        let main = record.main
        let value: Any?
        do {
            value = try await bounded(limit, stopsOnAsk: stopsOnAsk, leaves: stopsOnLeave ? { self.web.isLoading || self.record.main != main } : nil) {
                try await self.web.callAsyncJavaScript(body, arguments: arguments, in: info, contentWorld: LiveAgentScript.world)
            }
        } catch let error as LiveRefusal {
            throw error
        } catch let error as AskPending {
            throw error
        } catch let error as PageLeft {
            throw error
        } catch {
            let message = Self.message(error)
            if message == "GONE" { throw LiveRefusal("引用的元素已不在页面上（被页面换掉了）：重新 cuepad live snapshot") }
            if (error as NSError).code == WKError.javaScriptInvalidFrameTarget.rawValue { throw LiveRefusal("那个框已经不在了：重新 cuepad live snapshot") }
            throw LiveRefusal(message)
        }
        return value as? [String: Any] ?? [:]
    }

    /// 页面的脚本卡住时 `callAsyncJavaScript` 不回来、也不理取消：到点就不等它（它回来时没人收）。
    func bounded(_ limit: Duration, stopsOnAsk: Bool = false, leaves: (() -> Bool)? = nil, _ work: @escaping () async throws -> Any?) async throws -> Any? {
        let race = Race()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.continuation = continuation
                Task { do { race.finish(.success(try await work())) } catch { race.finish(.failure(error)) } }
                Task {
                    let deadline = ContinuousClock.now + limit
                    while race.continuation != nil, ContinuousClock.now < deadline {
                        if stopsOnAsk, !asks.isEmpty { return race.finish(.failure(AskPending())) }
                        if let leaves, leaves() { return race.finish(.failure(PageLeft())) }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    race.finish(.failure(LiveRefusal("页面 \(limit.components.seconds) 秒没答：页面的脚本可能卡住了（死循环、或弹着对话框）。cuepad live screenshot 看一眼")))
                }
            }
        } onCancel: {
            Task { @MainActor in race.finish(.failure(CancellationError())) }
        }
    }

    private final class Race {
        var continuation: CheckedContinuation<Any?, any Error>?

        func finish(_ result: sending Result<Any?, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }

    static func message(_ error: any Error) -> String {
        if let refusal = error as? LiveRefusal { return refusal.text }
        let info = (error as NSError).userInfo
        let text = info["WKJavaScriptExceptionMessage"] as? String ?? (error as NSError).localizedDescription
        return text.hasPrefix("Error: ") ? String(text.dropFirst(7)) : text
    }

    static func seconds(since start: ContinuousClock.Instant) -> String { seconds(ContinuousClock.now - start) }

    static func seconds(_ duration: Duration) -> String {
        let (seconds, atto) = duration.components
        return String(format: "%.1f 秒", Double(seconds) + Double(atto) / 1e18)
    }

    /// Agent 用上这一页（发来地址、做一件事）：窗口被盖住时网页照常画，没开在面板里就挂到看不见的窗口里（`LiveHost`）。
    /// 只在 Agent 用着时这样：没人看、Agent 也不用的页面照系统的规矩停下渲染，不白耗电。
    /// 这一下才切过来的回 true。
    @discardableResult
    func engage() -> Bool {
        agent.acted = .now
        guard !agentActive else { return false }
        agentActive = true
        watchesOcclusion(false)
        if panes == 0 { LiveHost.park(web, size: pageSize) }
        return true
    }

    /// 切成看得见后，新状态要过一拍才到网页进程：页面自己说看得见了再做事，不然这一件还按藏着的跑（最多等半秒）。
    private func untilVisible() async {
        for _ in 0..<30 {
            let state = try? await bounded(.milliseconds(500)) { try await self.web.evaluateJavaScript("document.visibilityState", contentWorld: .defaultClient) }
            if state as? String != "hidden" { return }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    func disengage() {
        guard agentActive else { return }
        agentActive = false
        watchesOcclusion(true)
        LiveHost.unpark(web)
    }

    /// 窗口被盖住时网页还画不画：不画时 requestAnimationFrame 一次不跑、定时器拖到每秒一个（实测），靠它出内容的页面 Agent 等不到。
    /// 私有开关（WKWebViewPrivate），哪版没了就照旧。建好后切换要等 WebKit 下次重算可见性才生效（被盖着时切了照样不画，实测），
    /// 拨一下 `isHidden` 让它当场重算；同一拍里拨回，屏上不闪。
    private func watchesOcclusion(_ on: Bool) {
        guard web.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) else { return }
        web.setValue(on, forKey: "windowOcclusionDetectionEnabled")
        web.isHidden = true
        web.isHidden = false
    }

    func enteredPane() {
        panes += 1
        Task { LiveHost.tidy() }
    }

    func leftPane() {
        panes -= 1
        parkIfLeft()
    }

    /// 面板拆下网页视图（`leftPane`）与它真的离开窗口（`PageView` 报）谁先谁后不一定：两头都来这里，后到的那一下挂回看不见的窗口。
    /// 挪到下一拍：AppKit 还在把它从窗口里拿下来时不改它的父视图。
    func parkIfLeft() {
        Task {
            guard panes == 0, agentActive, web.window == nil else { return }
            LiveHost.park(web, size: pageSize)
        }
    }

    /// Agent 刚做了一件：预览栏上的状态标亮着，3 秒没有下一件就灭。
    func touchedByAgent() async {
        if engage() { await untilVisible() }
        agent.used = .now
        agent.drivenUntil = .now + Self.drivenFor
        guard !driven else { return }
        driven = true
        Task {
            while ContinuousClock.now < agent.drivenUntil { try? await Task.sleep(until: agent.drivenUntil) }
            driven = false
        }
    }

    static let drivenFor = Duration.seconds(3)
}

extension LivePreview.PageAsk.Kind {
    /// 给 Agent 的说法（`LiveRefusal` 与控制台的对话框一行）。
    var shown: String {
        switch self {
        case .alert: "alert"
        case .confirm: "confirm"
        case .prompt: "prompt"
        }
    }
}
#endif
