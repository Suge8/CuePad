import CueStore
import Observation
import SwiftUI
import WebKit

/// 一个会话的活预览：这个会话正在开发的网页本身（`Workspace.livePreviews`，只在内存里）。
/// 每个会话一个 `WKWebView`、各用一份非持久的数据存储：两个会话开着同一个地址，登录状态也不串。
/// Mac 上网页直连本机的服务、自己探服务在不在；手机、iPad 上去 Mac 的流量都经隧道（`LiveLink`），服务在不在、有哪些地址看 Mac 的答复（`serving`）。
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
    @ObservationIgnored let web: PageView
    /// Agent 这几秒里在看、在点这一页：预览栏上亮着那个状态标。
    var driven = false
    /// 这个预览是哪个会话的（会话结束时释放它，`Workspace.keepLivePreviews`）。
    @ObservationIgnored var sessionID: String?
    #if os(macOS)
    /// 页面自己报的控制台、请求与文档（`LiveAgentScript`）。
    @ObservationIgnored let record = LivePageRecord()
    /// Agent 操作这一页用的状态（`LivePreview+Agent`）。
    @ObservationIgnored var agent = AgentState()
    /// 挂在几处预览面板里（`LiveWebView` 挂上加一、拆下减一）：0 是用户没开着这一页。
    @ObservationIgnored var panes = 0
    /// `cuepad live upload` 交来的文件放这里（`LivePreview.keep`），预览没了一起删。
    @ObservationIgnored let uploadFolder = URL.temporaryDirectory.appending(path: "cuepad-live-uploads/\(UUID().uuidString)", directoryHint: .isDirectory)
    /// Agent 在用这一页（`engage`，`Workspace.liveIdle` 里没再用就 `disengage`）：被盖住、没开在面板里也按看得见的跑。
    @ObservationIgnored var agentActive = false
    #else
    /// 走隧道的主机（Mac 本机的名字与地址，`LiveTunnel.Proxy.isMac`）：只对它们放过 https 的证书校验，隧道两头已用 PSK 互认。
    @ObservationIgnored var tunneled: Set<String> = []
    /// 看得见时去 Mac 的路（`Workspace.connectLive`），收起就没有。
    var link: LiveLink?
    /// 跟过的 Agent 发来的地址（`follow`，按发来的时刻认）。
    @ObservationIgnored private var sentTaken: Date?
    /// 这一页的数据存储：代理设在它上面（`LiveLink`），只管这一个预览；登录状态跟着预览留到离开会话页（`Workspace.keepLivePreviews`）。
    @ObservationIgnored let dataStore = WKWebsiteDataStore.nonPersistent()
    #endif
    private(set) var address: URL?
    private(set) var source = Source.typed
    /// 认出的这个会话的服务（`Workspace.watchLiveServers` 每隔 `liveScan` 给）：认出来的地址在不在只看它——端口空出来后被别的进程占了，答得上话也不是这个会话的页。
    /// 手机、iPad 上是 Mac 答来的这个会话的页面，隧道不通时为 nil（`LiveLink` 经 `serve` 给）：页面在不在全看它，手机探不到 Mac 的回环。地址栏里列的其余地址也是它。
    @ObservationIgnored var serving: [URL]?
    private(set) var phase = Phase.blank
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
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
        #if os(macOS)
        configuration.websiteDataStore = .nonPersistent()
        #else
        configuration.websiteDataStore = dataStore
        #endif
        // macOS 上默认开着：不经点击（定时器里）的 window.open 也会开，外部地址就一个个塞进默认浏览器（`LivePreview+Dialogs`）
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        #if os(macOS)
        let content = configuration.userContentController
        content.addUserScript(WKUserScript(source: LiveAgentScript.hooks, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        content.addUserScript(WKUserScript(source: LiveAgentScript.agent, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: LiveAgentScript.world))
        content.add(record, contentWorld: .page, name: LivePageRecord.logChannel)
        content.add(record, contentWorld: LiveAgentScript.world, name: LivePageRecord.agentChannel)
        // 没开过面板就被 Agent 用上的（后台载入）也要有个视口：页面按它排版，取面板上次的大小（`LiveHost.park` 再按宽度档定）
        web = PageView(frame: CGRect(origin: .zero, size: LivePreviewPane.page(in: Self.paneSize, phone: false)), configuration: configuration)
        #else
        web = PageView(frame: .zero, configuration: configuration)
        #endif
        web.isInspectable = true
        web.allowsBackForwardNavigationGestures = true
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        #if os(macOS)
        web.leftWindow = { [weak self] in self?.parkIfLeft() }
        #endif
        observations = [
            web.observe(\.url) { [weak self] web, _ in MainActor.assumeIsolated { self?.url = web.url } },
            web.observe(\.isLoading) { [weak self] web, _ in MainActor.assumeIsolated { self?.isLoading = web.isLoading } },
            web.observe(\.estimatedProgress) { [weak self] web, _ in MainActor.assumeIsolated { self?.progress = web.estimatedProgress } },
            web.observe(\.canGoBack) { [weak self] web, _ in MainActor.assumeIsolated { self?.canGoBack = web.canGoBack } },
            web.observe(\.canGoForward) { [weak self] web, _ in MainActor.assumeIsolated { self?.canGoForward = web.canGoForward } },
        ]
    }

    #if os(macOS)
    deinit { try? FileManager.default.removeItem(at: uploadFolder) }
    #endif

    /// 手里这个地址留着：有地址、而且不是按认出的开的又不在了（`found` 是此刻认出的服务）。认出的跟着服务换端口，你填的、Agent 发来的不跟。
    /// 两端同一条：Mac 的开合与扫描（`Workspace.scanLive`）、手机跟 Mac 的答复（`follow`）。
    func keeps(_ found: [URL]) -> Bool {
        guard let address else { return false }
        return source != .found || found.contains(address)
    }

    /// Agent 新发来的地址换不换过去：开着、是你自己填的那一页不被顶掉，留到下次打开。两端同一条（Mac 的 `Workspace.receive`、手机的 `follow`）。
    func yields(showing: Bool) -> Bool { !(showing && address != nil && source == .typed) }

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

    /// 面板上次开着时的大小（`LivePreviewPane` 报）：后台的预览按它与这一页的宽度档开视口（`pageSize`）。
    static var paneSize = CGSize(width: 800, height: 900)

    var pageSize: CGSize { LivePreviewPane.page(in: Self.paneSize, phone: viewport == .phone) }

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
        let found = try? await run(LivePick.script, arguments: pickColors)
        return (found as? [String: Any]).flatMap(LivePick.element)
    }

    /// 高亮的颜色按网页视图此刻的深浅色（`LivePick.colors`）。
    var pickColors: [String: String] {
        #if os(macOS)
        LivePick.colors(dark: web.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        #else
        LivePick.colors(dark: web.traitCollection.userInterfaceStyle == .dark)
        #endif
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
        #if os(macOS)
        if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
            record.note("network", "\(navigationResponse.isForMainFrame ? "页面" : "框") \(http.url?.absoluteString ?? "") → \(http.statusCode)")
        }
        #endif
        return .allow
    }

    #if os(iOS)
    /// 开发服务的 https（mkcert、自签）手机不信 Mac 上的根证书：走隧道的主机放过，别的照系统的校验。
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust,
              LiveTunnel.Proxy.isMac(space.host, addresses: tunneled) else { return (.performDefaultHandling, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
    #endif

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        #if os(macOS)
        if (error as NSError).code != NSURLErrorCancelled { record.note("network", "页面载不出：\(error.localizedDescription)") }
        #endif
        guard Self.unreachable(error) else { return }
        phase = painted ? .stopped : .waiting
    }

    /// 面板开着时在后台每秒探一次（`LivePreviewPane` 的 task 里跑，收起就停）：等着的起来了就载入，载出过的停了就标出来、回来了重新载入。
    func watch() async {
        #if os(macOS)
        if phase == .idle, let address { load(address) }
        #else
        if phase == .idle { phase = .waiting }
        #endif
        while !Task.isCancelled {
            await check()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func check() async {
        guard let address, phase != .blank else { return }
        let up = await isUp(address)
        // 面板收起时取消的那一下探不到，不是服务停了：当成停了，下次打开或 Agent 再操作时页面会被重新载入
        guard !Task.isCancelled else { return }
        // 探的这一会儿换了地址：这一次的结果说的是旧地址
        guard address == self.address else { return }
        switch phase {
        case .waiting where up: load(address)
        case .stopped where up: resume(address)
        case .live where !up && painted: phase = .stopped
        case .live: await sampleGround()
        default: break
        }
    }

    #if os(iOS)
    /// Mac 答来的页面变了、隧道断了（`LiveLink`）：当场照它判一次，不等下一秒的探。
    func serve(_ pages: [URL]?) {
        serving = pages
        guard phase != .idle else { return }
        Task { await check() }
    }

    /// 手机、iPad 跟 Mac 的答复（开着时 `LiveLink`，收着的再点开时 `Workspace.toggleLivePreview`），规则同 Mac 的开合、扫描与收 Agent 地址（`keeps`、`yields`）：
    /// Agent 新发来的换过去；按认出的开的、服务不在了换 Mac 答的第一个；还没有地址的用第一个，当时已发来的算看过。
    func follow(_ answer: LiveRemote.Pages, showing: Bool) {
        if let sent = answer.sent, sent.sentAt != sentTaken, address == nil || yields(showing: showing) {
            sentTaken = sent.sentAt
            if address != nil { return retarget(.init(url: sent.url, source: sent.found ? .found : .sent)) }
        }
        guard !keeps(answer.serving), let first = answer.pages.first else { return }
        // 不在认出的服务里的（Agent 发来的、Mac 上填的）记作发来的：记作认出的，下一次答复见它不在认出的里又要换
        retarget(.init(url: first, source: answer.serving.contains(first) ? .found : .sent))
    }

    /// 隧道通了（`LiveLink`）。载出过画面的是断过再通（收起再开、回到前台、换网、Mac 醒来、换了票据）：整页重新载入一次，
    /// 页面里的热更新连接断在旧隧道上，不指望开发服务的客户端自己重连。第一次通照 `serve`：还没载过的这就载。
    func linked(_ pages: [URL]) {
        guard painted, let address, phase != .idle, serves(address, pages) else { return serve(pages) }
        serving = pages
        resume(address)
    }
    #endif

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

    #if os(macOS)
    private static let probe: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private func isUp(_ address: URL) async -> Bool {
        if source == .found, let serving { serving.contains(address) } else { await Self.reachable(address) }
    }

    /// 有任何 HTTP 回应就算服务在（404 也是）。
    private static func reachable(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        return (try? await probe.data(for: request)) != nil
    }
    #else
    private func isUp(_ address: URL) async -> Bool { serves(address, serving ?? []) }

    /// 同一个服务（协议、主机、端口）在 Mac 答来的页面里。
    private func serves(_ address: URL, _ pages: [URL]) -> Bool {
        pages.contains { $0.scheme == address.scheme && $0.host() == address.host() && $0.port == address.port }
    }
    #endif

    /// 连不上主机那一类；按停止、换地址打断的那一次（取消）不算。
    private static func unreachable(_ error: any Error) -> Bool {
        (error as NSError).domain == NSURLErrorDomain && (error as NSError).code != NSURLErrorCancelled
    }
}

#if os(iOS)
typealias PageView = WKWebView
#endif
