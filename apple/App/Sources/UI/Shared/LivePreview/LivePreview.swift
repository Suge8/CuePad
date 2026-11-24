import CueStore
import Observation
import SwiftUI
import WebKit

/// 一个会话的活预览：这个会话正在开发的网页本身（`LivePreviews` 里载入了的那一项，只在内存里）。
/// 每个会话一个 `WKWebView`、各用一份非持久的数据存储：两个会话开着同一个地址，登录状态也不串。
/// Mac 上网页直连本机的服务、自己探服务在不在；手机、iPad 上去 Mac 的流量都经隧道（`LiveLink`），服务在不在看隧道那头到得了哪些页（`reachable`）。
/// 网页不伸到玻璃栏后面（`LivePreviewPane.screen`）：SwiftUI 的 `WebView` 公开接口里没有遮挡区（macOS 26 SDK 的 `_WebKit_SwiftUI`），
/// `WKWebView` 的 `obscuredContentInsets` 让出的那一截 WebKit 自己画一道硬边的带（浅色白、深色灰，公开接口改不了），两档视口切换时内边距还要跳。
@Observable
final class LivePreview: NSObject, WKNavigationDelegate {
    enum Phase: Equatable {
        case idle
        case live
        case waiting
        case stopped
    }

    enum Viewport { case fill, phone }

    enum Source { case typed, sent, found }

    struct Target: Equatable {
        let url: URL
        let source: Source
    }

    static let phoneWidth: CGFloat = 390
    static let phoneHeight: CGFloat = 844

    @ObservationIgnored let web: PageView
    var driven = false
    let sessionID: String
    #if os(macOS)
    @ObservationIgnored let record = LivePageRecord()
    @ObservationIgnored var agent = AgentState()
    @ObservationIgnored var panes = 0
    @ObservationIgnored let uploadFolder = URL.temporaryDirectory.appending(path: "cuepad-live-uploads/\(UUID().uuidString)", directoryHint: .isDirectory)
    @ObservationIgnored var agentActive = false
    #else
    @ObservationIgnored var tunneled: Set<String> = []
    var link: LiveLink?
    @ObservationIgnored var host: String?
    /// 隧道那头此刻到得了的页（`LiveLink` 给）；没连着时是 nil：不知道，不算服务停了。
    @ObservationIgnored private(set) var reachable: [URL]?
    @ObservationIgnored let dataStore = WKWebsiteDataStore.nonPersistent()
    #endif
    private(set) var address: URL
    private(set) var source: Source
    private(set) var phase = Phase.idle
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    var viewport = Viewport.fill { didSet { adopted = false } }
    @ObservationIgnored private var adopted = false
    /// 这个地址第一次载完：之前网页还是 WebKit 的默认底（深色下也是一块白），先不露出来。
    private(set) var revealed = false
    private(set) var ground: Color?
    var asks: [PageAsk] = []
    @ObservationIgnored private var painted = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(sessionID: String, target: Target) {
        self.sessionID = sessionID
        address = target.url
        source = target.source
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

    var target: Target { Target(url: address, source: source) }

    var shownAddress: URL { url ?? address }

    func retarget(_ target: Target) {
        address = target.url
        source = target.source
        painted = false
        revealed = false
        if phase != .idle { load(target.url) }
    }

    func reload() { load(shownAddress) }

    private func resume(_ address: URL) {
        let here = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let home = URLComponents(url: address, resolvingAgainstBaseURL: false)
        if let here, let url, here.scheme == home?.scheme, here.host == home?.host, here.port == home?.port { load(url) } else { load(address) }
    }

    func stopLoading() { web.stopLoading() }

    func start() {
        if phase == .idle { load(address) }
    }

    static var paneSize = CGSize(width: 800, height: 900)

    var pageSize: CGSize { LivePreviewPane.page(in: Self.paneSize, phone: viewport == .phone) }

    func run(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await web.callAsyncJavaScript(script, arguments: arguments, contentWorld: .page)
    }

    private(set) var picking = false

    func pick() async -> ReplyNote.Element? {
        picking = true
        defer { picking = false }
        let found = try? await run(LivePick.script, arguments: pickColors)
        return (found as? [String: Any]).flatMap(LivePick.element)
    }

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
            await adoptViewport()
            revealed = true
        }
    }

    private func adoptViewport() async {
        if (try? await run(Self.viewportScript) as? String) == "phone" {
            viewport = .phone
            adopted = true
        } else if adopted {
            viewport = .fill
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

    /// 载入了就一直探着（`LivePreviews` 起、放掉时停），不跟着面板：没开在面板里、Agent 发来时服务还没起来，起来了照样载出。
    func watch() async {
        #if os(macOS)
        start()
        #else
        if phase == .idle { phase = .waiting }
        #endif
        while !Task.isCancelled {
            await check()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func check() async {
        let address = address
        guard let up = await isUp(address), !Task.isCancelled, address == self.address else { return }
        switch phase {
        case .waiting where up: load(address)
        case .stopped where up: resume(address)
        case .live where !up && painted: phase = .stopped
        case .live: await sampleGround()
        default: break
        }
    }

    #if os(iOS)
    func serve(_ pages: [URL]?) {
        reachable = pages
        guard phase != .idle else { return }
        Task { await check() }
    }

    func linked(_ pages: [URL]) {
        guard painted, phase != .idle, serves(address, pages) else { return serve(pages) }
        reachable = pages
        resume(address)
    }
    #endif

    private func sampleGround() async {
        guard let css = try? await run(Self.groundScript) as? String, let color = Color.webPage(css), color != ground else { return }
        ground = color
    }

    #if os(macOS)
    private static let probe: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private func isUp(_ address: URL) async -> Bool? {
        var request = URLRequest(url: address)
        request.httpMethod = "HEAD"
        return (try? await Self.probe.data(for: request)) != nil
    }
    #else
    private func isUp(_ address: URL) async -> Bool? { reachable.map { serves(address, $0) } }

    private func serves(_ address: URL, _ pages: [URL]) -> Bool {
        pages.contains { $0.scheme == address.scheme && $0.host() == address.host() && $0.port == address.port }
    }
    #endif

    private static func unreachable(_ error: any Error) -> Bool {
        (error as NSError).domain == NSURLErrorDomain && (error as NSError).code != NSURLErrorCancelled
    }
}

#if os(iOS)
typealias PageView = WKWebView
#endif
