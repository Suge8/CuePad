#if os(macOS)
import CueStore
import Observation
import SwiftUI
import WebKit

/// 一个会话的活预览：这个会话正在开发的网页本身（`Workspace.livePreviews`，只在内存里）。
/// 每个会话一个 `WKWebView`、各用一份非持久的数据存储：两个会话开着同一个地址，登录状态也不串。
/// 网页不伸到玻璃栏后面（`LivePreviewPane.screen`）：SwiftUI 的 `WebView` 公开接口里没有遮挡区（macOS 26 SDK 的 `_WebKit_SwiftUI`），
/// `WKWebView` 的 `obscuredContentInsets` 让出的那一截 WebKit 自己画一道硬边的带（浅色白、深色灰，公开接口改不了），两档视口切换时内边距还要跳。
@Observable
final class LivePreview: NSObject, WKNavigationDelegate {
    enum Phase: Equatable {
        /// 还没有地址。
        case blank
        /// 有地址、面板还没开过：开了才载入（`watch`），没人看的会话不白占一份网页。
        case idle
        /// 载入中或已载入。
        case live
        /// 连不上、还没载出过画面：在后台每秒探一次，起来了自动载入。
        case waiting
        /// 载出过画面、服务停了：留着最后的画面，回来了自动重新载入。
        case stopped
    }

    enum Viewport { case fill, phone }

    /// 地址从哪来：你输入或挑的、Agent 用 `cuepad live` 明说的、认出来的（`LiveServers`）。只有认出来的跟着服务换端口。
    enum Source { case typed, sent, found }

    struct Target: Equatable {
        let url: URL
        let source: Source
    }

    static let phoneWidth: CGFloat = 390
    static let phoneHeight: CGFloat = 844

    /// 同一时刻只挂在一处（`LiveWebView`）。
    @ObservationIgnored let web: WKWebView
    /// 页面自己报的控制台、请求与文档（`LiveAgentScript`）。
    @ObservationIgnored let record = LivePageRecord()
    /// Agent 操作这一页用的状态（`LivePreview+Agent`）。
    @ObservationIgnored var agent = AgentState()
    /// Agent 这几秒里在看、在点这一页：预览栏上亮着那个状态标。
    var driven = false
    /// 这个预览是哪个会话的（会话结束时释放它，`Workspace.keepLivePreviews`）。
    @ObservationIgnored var sessionID: String?
    private(set) var address: URL?
    private(set) var source = Source.typed
    /// 认出的这个会话的服务（`Workspace.watchLiveServers` 每隔 `liveScan` 给）：认出来的地址在不在只看它——端口空出来后被别的进程占了，答得上话也不是这个会话的页。
    @ObservationIgnored var serving: [URL]?
    private(set) var phase = Phase.blank
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var progress = 0.0
    var viewport = Viewport.fill
    /// 这个地址第一次载完：之前网页还是 WebKit 的默认底（深色下也是一块白），先不露出来。
    private(set) var revealed = false
    /// 页面的底色（`<html>`，没有就 `<body>`，都透明就是浏览器默认的画布色）：玻璃栏后面让出的那一截与手机屏的底接上它。
    private(set) var ground: Color?
    /// 网页弹的 alert、confirm、prompt，还没答的（`LivePreview+Dialogs`）。
    var asks: [PageAsk] = []
    /// 这个地址载出过画面（提交过一次）：之后连不上是"停了"，不是"还没起来"。
    @ObservationIgnored private var painted = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // macOS 上默认开着：不经点击（定时器里）的 window.open 也会开，外部地址就一个个塞进默认浏览器（`LivePreview+Dialogs`）
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Agent 多在 CuePad 被盖住、或预览没开时操作这一页：网页当它藏着，定时器从第十来个起拖到每个 1 秒（实测 50 ms 的成了 1000 ms），
        // `inactiveSchedulingPolicy = .none` 管不到这一条。私有开关（WKPreferencesPrivate），哪版没了就照旧节流
        if configuration.preferences.responds(to: NSSelectorFromString("_setHiddenPageDOMTimerThrottlingEnabled:")) {
            configuration.preferences.setValue(false, forKey: "hiddenPageDOMTimerThrottlingEnabled")
        }
        let content = configuration.userContentController
        content.addUserScript(WKUserScript(source: LiveAgentScript.hooks, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        content.addUserScript(WKUserScript(source: LiveAgentScript.agent, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: LiveAgentScript.world))
        content.add(record, contentWorld: .page, name: LivePageRecord.logChannel)
        content.add(record, contentWorld: LiveAgentScript.world, name: LivePageRecord.agentChannel)
        // 没开过面板就被 Agent 用上的（后台载入）也要有个视口：页面按它排版，取面板上次的大小
        web = WKWebView(frame: CGRect(origin: .zero, size: Self.paneSize), configuration: configuration)
        web.isInspectable = true
        // 窗口被盖住时网页照常画：不然 requestAnimationFrame 一次不跑（实测），靠它出内容的页面 Agent 等不到。
        // 私有开关（WKWebViewPrivate）；没开的后台预览不在窗口里，这条帮不到它
        if web.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
            web.setValue(false, forKey: "windowOcclusionDetectionEnabled")
        }
        web.allowsBackForwardNavigationGestures = true
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        observations = [
            web.observe(\.url) { [weak self] web, _ in MainActor.assumeIsolated { self?.url = web.url } },
            web.observe(\.isLoading) { [weak self] web, _ in MainActor.assumeIsolated { self?.isLoading = web.isLoading } },
            web.observe(\.estimatedProgress) { [weak self] web, _ in MainActor.assumeIsolated { self?.progress = web.estimatedProgress } },
        ]
    }

    /// 地址栏里显示的：此刻页面所在（页内跳转跟着变），还没载过就是输入的地址。
    var shownAddress: URL? { url ?? address }

    /// 换一个地址：载入过的接着就载（面板收着也载，开时已是新页面），还没载入过的等面板开。
    func retarget(_ target: Target) {
        address = target.url
        source = target.source
        painted = false
        revealed = false
        if phase == .blank || phase == .idle { phase = .idle } else { load(target.url) }
    }

    func reload() {
        guard let url = shownAddress else { return }
        load(url)
    }

    /// 停了的服务回来时接回的页：页面跳到了别的主机或端口就回会话的地址，那个口此刻是谁的不知道，探活认过的只有会话的地址。
    private func resume(_ address: URL) {
        let here = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let home = URLComponents(url: address, resolvingAgainstBaseURL: false)
        if let here, let url, here.scheme == home?.scheme, here.host == home?.host, here.port == home?.port { load(url) } else { load(address) }
    }

    func stopLoading() { web.stopLoading() }

    /// 有地址、还没载过的现在就载（Agent 发来地址时，面板没开也载：之后它要操作的就是这一页）。
    func start() {
        if phase == .idle, let address { load(address) }
    }

    /// 面板上次的大小（`LivePreviewPane` 报）：后台建的预览按它开视口，用户点开时页面不用换一套排版。
    static var paneSize = CGSize(width: 800, height: 900)

    /// 在页面自己的内容世界里跑一段函数体（`callAsyncJavaScript`：可以 `await`、`return`，参数按名字成了局部变量）。
    func run(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await web.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
    }

    /// 点选开着：指着的元素有一层高亮框，点一下就是它（这一下不交给页面）。
    private(set) var picking = false

    /// 等你在页面上点一个元素：Esc、再点那颗钮（`cancelPick`）、页面换了都算不点，返回 nil。
    func pick() async -> ReplyNote.Element? {
        picking = true
        defer { picking = false }
        let found = try? await run(LivePick.script, arguments: LivePick.colors)
        return (found as? [String: Any]).flatMap(LivePick.element)
    }

    func cancelPick() {
        Task { _ = try? await run(LivePick.cancel) }
    }

    private func load(_ url: URL) {
        phase = .live
        web.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { painted = true }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            await sampleGround()
            revealed = true
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
            record.note("network", "\(navigationResponse.isForMainFrame ? "页面" : "框") \(http.url?.absoluteString ?? "") → \(http.statusCode)")
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if (error as NSError).code != NSURLErrorCancelled { record.note("network", "页面载不出：\(error.localizedDescription)") }
        guard Self.unreachable(error) else { return }
        phase = painted ? .stopped : .waiting
    }

    /// 面板开着时在后台每秒探一次（`LivePreviewPane` 的 task 里跑，收起就停）：等着的起来了就载入，载出过的停了就标出来、回来了重新载入。
    func watch() async {
        if phase == .idle, let address { load(address) }
        while !Task.isCancelled {
            if let address, phase != .blank {
                let up = if source == .found, let serving { serving.contains(address) } else { await Self.reachable(address) }
                // 探的这一会儿换了地址：这一次的结果说的是旧地址
                if address == self.address {
                    switch phase {
                    case .waiting where up: load(address)
                    case .stopped where up: resume(address)
                    case .live where !up && painted: phase = .stopped
                    case .live: await sampleGround()
                    default: break
                    }
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// 页面跟着深浅色换了底、热更新换了样式都要跟上：载完读一次，之后随探活每秒读一次。
    private func sampleGround() async {
        guard let css = try? await run(Self.groundScript) as? String, let color = Color.webPage(css), color != ground else { return }
        ground = color
    }

    private static let groundScript = """
        const solid = element => {
            const color = element && getComputedStyle(element).backgroundColor;
            return color && !/^(transparent|rgba\\(.*,\\s*0\\))$/.test(color) ? color : null;
        };
        const canvas = () => {
            const probe = document.createElement("div");
            probe.style.background = "Canvas";
            document.documentElement.append(probe);
            const color = getComputedStyle(probe).backgroundColor;
            probe.remove();
            return color;
        };
        return solid(document.documentElement) ?? solid(document.body) ?? canvas();
        """

    private static let probe: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// 有任何 HTTP 回应就算服务在（404 也是）。
    private static func reachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        return (try? await probe.data(for: request)) != nil
    }

    /// 连不上主机那一类；按停止、换地址打断的那一次（取消）不算。
    private static func unreachable(_ error: any Error) -> Bool {
        (error as NSError).domain == NSURLErrorDomain && (error as NSError).code != NSURLErrorCancelled
    }
}
#endif
