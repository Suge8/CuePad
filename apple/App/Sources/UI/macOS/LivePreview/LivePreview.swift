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
    /// 这个地址载出过画面（提交过一次）：之后连不上是"停了"，不是"还没起来"。
    @ObservationIgnored private var painted = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: .zero, configuration: configuration)
        web.isInspectable = true
        web.allowsBackForwardNavigationGestures = true
        super.init()
        web.navigationDelegate = self
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

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
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

extension Workspace {
    /// 会话页栏头那颗钮与菜单里的"打开活预览"：左边那个会话的活预览在右半开、收（开着并排的会话时换掉它）。第一次打开时给这个会话建一份；
    /// 先用 Agent 发来的（`cuepad live`），再用你填过的，没有或认出的那个已不在了才换认出的服务里最近起来的，都没有是空的地址输入。
    func toggleLivePreview() {
        guard case .wide(var state) = navigation, !state.home, case .session(let session) = state.main else { return }
        if state.beside == .preview {
            state.beside = nil
        } else {
            let preview = livePreviews[session.id] ?? LivePreview()
            livePreviews[session.id] = preview
            if let sent = liveSent.removeValue(forKey: session.id) {
                preview.retarget(sent)
            } else if let found = liveFound[session.id], let first = found.first, !Self.keeps(preview, found) {
                preview.retarget(.init(url: first, source: .found))
            }
            state.beside = .preview
        }
        navigation = .wide(state)
    }

    /// 有地址、而且不是认出过又不在了的（认出的地址只认 `liveFound`）。
    private static func keeps(_ preview: LivePreview, _ found: [URL]) -> Bool {
        guard let address = preview.address else { return false }
        return preview.source != .found || found.contains(address)
    }

    /// 这个会话有没有页面可看（会话条那一行带不带标，栏头那颗预览钮在不在也从它起）：认出了它的服务、Agent 发来过地址（`cuepad live`）、
    /// 你给它填过地址。按认出的地址开过、服务已不在的不算。
    func hasLivePage(_ session: UUID) -> Bool {
        liveFound[session]?.isEmpty == false || liveSent[session] != nil || livePreviews[session].map { Self.keeps($0, []) } ?? false
    }

    private func showsLivePreview(_ session: UUID) -> Bool { beside == .preview && self.session(in: .main)?.id == session }

    enum LiveButton: Equatable {
        /// 点开就是这个地址；nil 是空的地址输入。
        case closed(URL?)
        case open(URL?)

        var isShowing: Bool { if case .open = self { true } else { false } }
    }

    /// nil：没有页面可看、预览也没开着，栏头不放这颗钮（手动打开在会话的菜单里，`openLivePreview`）。开着空的地址输入也有它：收起只有这一处。
    func liveButton(_ session: UUID) -> LiveButton? {
        if showsLivePreview(session) { return .open(livePreviews[session]?.address) }
        guard hasLivePage(session) else { return nil }
        let found = liveFound[session] ?? []
        let kept = livePreviews[session].flatMap { Self.keeps($0, found) ? $0.address : nil }
        return .closed(liveSent[session]?.url ?? kept ?? found.first)
    }

    /// 会话的菜单里的"打开活预览"（只在这个会话还没有页面可看、栏头没有那颗钮时有）：会话放到主区，右半滑开空的地址输入。
    func openLivePreview(_ session: SessionState) {
        if self.session(in: .main)?.id != session.id { openSession(session.id, sessionID: session.sessionID, in: .main) }
        if beside != .preview { toggleLivePreview() }
    }

    /// 活预览只看这台 Mac 上的会话（本机的服务、本机的 localhost）。
    func livesHere(_ session: SessionState) -> Bool { Self.liveHosts(services).contains(session.hostID) }

    private static func liveHosts(_ services: AppServices) -> [String] { [services.hostID] + DebugHooks.liveHosts }

    /// Agent 发来的地址（`cuepad live`）记到会话上；会话此刻在主区、右半空着就直接滑开，否则只让栏头那颗钮亮起，不动排布。
    func followLiveAddresses() async {
        // App 起来之前发的不算（那时的服务多半已经不在了）；起来之后、订阅开始之前发的照收
        let start = LiveServers.launched() ?? .now
        var seen: [String: Date]?
        do {
            for try await addresses in services.store.observe({ try $0.liveAddresses() }) {
                let fresh = addresses.filter { address in seen.map { $0[address.sessionID].map { address.sentAt > $0 } ?? true } ?? (address.sentAt > start) }
                seen = Dictionary(addresses.map { ($0.sessionID, $0.sentAt) }, uniquingKeysWith: max)
                for address in fresh { receive(address) }
            }
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    private func receive(_ address: LiveAddress) {
        let id = SessionState.recordID(sessionID: address.sessionID)
        let target = LivePreview.Target(url: address.url, source: address.found ? .found : .sent)
        let here = session(in: .main)?.id == id
        // 开着的预览只在空着或显示的也是 Agent 给、认出的地址时换；你输入的不被顶掉，这一条留到下次打开
        if here, beside == .preview, let preview = livePreviews[id], preview.address == nil || preview.source != .typed { return preview.retarget(target) }
        liveSent[id] = target
        if here, beside == nil { toggleLivePreview() }
    }

    /// 窗口有人看着时（`ViewerKeeper.present`，`MainWindow` 挂着）每隔 `liveScan` 扫一遍本机进程表，把在监听、答得出网页的口归给本机没结束的各个会话：
    /// 栏头的预览钮与会话条的标都读它。扫一遍的开销不随会话多少变（`LiveServers.find`）。
    /// 开着的预览跟着它：按认出的地址开的，地址不在了、又认出了别的（5173 被占换到 5174）就跟过去；空着地址的，认出了就载入。
    func watchLiveServers() async {
        var servers = LiveServers()
        while !Task.isCancelled {
            var owners = (try? await services.store.liveOwners(hosts: Self.liveHosts(services))) ?? [:]
            for (sessionID, owner) in owners where owner.directory?.isEmpty != false {
                owners[sessionID]?.directory = services.bridge.session(sessionID: sessionID)?.cwd.path
            }
            let found = await servers.find(for: owners).reduce(into: [UUID: [URL]]()) { $0[SessionState.recordID(sessionID: $1.key)] = $1.value }
            if liveFound != found { liveFound = found }
            for (id, preview) in livePreviews {
                let urls = found[id] ?? []
                preview.serving = urls
                if let first = urls.first, !Self.keeps(preview, urls) { preview.retarget(.init(url: first, source: .found)) }
            }
            try? await Task.sleep(for: Self.liveScan)
        }
    }

    /// 2 秒：服务起来到钮出现等得住。实测本机约 1,600 个进程时一遍 10 个会话中位 3.7 ms、50 个 4.7 ms，大头是读全部监听口，不随会话数涨。
    static let liveScan = Duration.seconds(2)

    /// 预览栏上的点选钮：开着就收，没开就开；点中的元素挂进左边会话的回复框（`ReplyNote.Element`），回复框接过焦点，接着写那一句。
    func pickElement() {
        guard let session = session(in: .main), let preview = livePreviews[session.id] else { return }
        if preview.picking { return preview.cancelPick() }
        Task {
            guard let element = await preview.pick() else { return }
            services.settings.quote(element, for: session.id)
            replyFocus = session.id
        }
    }
}
#endif
