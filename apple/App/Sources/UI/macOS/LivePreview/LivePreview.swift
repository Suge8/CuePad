#if os(macOS)
import Observation
import SwiftUI
import WebKit

/// 一个会话的活预览：这个会话正在开发的网页本身（`Workspace.livePreviews`，只在内存里）。
/// 每个会话一个 `WebPage`、各用一份非持久的数据存储：两个会话开着同一个地址，登录状态也不串。
/// 同一时刻只能有一个视图持有它：SwiftUI 的 `WebView` 不许两个视图共用一个 `WebPage`（`PreviewWeb` 头注释）。
@Observable
final class LivePreview {
    enum Phase: Equatable {
        /// 还没有地址。
        case blank
        /// 载入中或已载入。
        case live
        /// 连不上、还没载出过画面：在后台每秒探一次，起来了自动载入。
        case waiting
        /// 载出过画面、服务停了：留着最后的画面，回来了自动重新载入。
        case stopped
    }

    enum Viewport { case fill, phone }

    static let phoneWidth: CGFloat = 390
    static let phoneHeight: CGFloat = 844

    let page: WebPage
    private(set) var address: URL?
    private(set) var phase = Phase.blank
    var viewport = Viewport.fill
    /// 页面的底色（`<html>`，没有就 `<body>`，都透明就是浏览器默认的画布色）：玻璃栏后面让出的那一截与手机屏的底接上它。
    private(set) var ground: Color?
    /// 这个地址载出过画面（提交过一次）：之后连不上是"停了"，不是"还没起来"。
    @ObservationIgnored private var painted = false
    @ObservationIgnored private var loading: Task<Void, Never>?

    init() {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        page = WebPage(configuration: configuration)
        page.isInspectable = true
    }

    /// 地址栏里显示的：此刻页面所在（页内跳转跟着变），还没载过就是输入的地址。
    var shownAddress: URL? { page.url ?? address }

    func open(_ url: URL) {
        address = url
        painted = false
        load(url)
    }

    func reload() {
        guard let url = shownAddress else { return }
        load(url)
    }

    func stopLoading() { page.stopLoading() }

    /// 点选开着：指着的元素有一层高亮框，点一下就是它（这一下不交给页面）。
    private(set) var picking = false

    /// 等你在页面上点一个元素：Esc、再点那颗钮（`cancelPick`）、页面换了都算不点，返回 nil。
    func pick() async -> ReplyNote.Element? {
        picking = true
        defer { picking = false }
        let found = try? await page.callJavaScript(LivePick.script, arguments: LivePick.colors)
        return (found as? [String: Any]).flatMap(LivePick.element)
    }

    func cancelPick() {
        Task { _ = try? await page.callJavaScript(LivePick.cancel) }
    }

    private func load(_ url: URL) {
        phase = .live
        let events = page.load(URLRequest(url: url))
        loading?.cancel()
        loading = Task { [weak self] in
            do {
                for try await event in events {
                    if event == .committed { self?.painted = true }
                    if event == .finished { await self?.sampleGround() }
                }
            } catch {
                guard let self, !Task.isCancelled, Self.unreachable(error) else { return }
                phase = painted ? .stopped : .waiting
            }
        }
    }

    /// 面板开着时在后台每秒探一次（`LivePreviewPane` 的 task 里跑，收起就停）：等着的起来了就载入，载出过的停了就标出来、回来了重新载入。
    func watch() async {
        while !Task.isCancelled {
            if let address, phase != .blank {
                let up = await Self.reachable(address)
                // 探的这一会儿换了地址：这一次的结果说的是旧地址
                if address == self.address {
                    switch phase {
                    case .waiting where up: load(address)
                    case .stopped where up: reload()
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
        guard let css = try? await page.callJavaScript(Self.groundScript) as? String, let color = Color.webPage(css), color != ground else { return }
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
        guard case WebPage.NavigationError.failedProvisionalNavigation(let underlying) = error else { return false }
        return (underlying as? URLError)?.code != .cancelled && (underlying as NSError).code != NSURLErrorCancelled
    }

    /// 地址栏里写的：不写 http://、https://，路径只有 "/" 时也不写。
    static func shown(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = components.host else { return url.absoluteString }
        let port = components.port.map { ":\($0)" } ?? ""
        let path = components.path == "/" ? "" : components.path
        return host + port + path + (components.query.map { "?\($0)" } ?? "")
    }

    /// 地址栏里输入的：只写端口（5173）当作本机；不写协议时本机、局域网与不带点的主机名用 http，其余用 https。
    static func url(from text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let port = Int(text), (1...65_535).contains(port) { return URL(string: "http://localhost:\(port)") }
        let full: String
        if text.contains("://") {
            full = text
        } else {
            let host = text.prefix { !":/?#".contains($0) }
            let local = !host.contains(".") || host.hasSuffix(".local") || host.allSatisfy { $0.isNumber || $0 == "." }
            full = (local ? "http://" : "https://") + text
        }
        guard let url = URL(string: full), url.host?.isEmpty == false else { return nil }
        return url
    }
}

extension Workspace {
    /// 会话页栏头那颗钮与预览栏上的收起：左边那个会话的活预览在右半开、收（开着并排的会话时换掉它）。第一次打开时给这个会话建一份。
    func toggleLivePreview() {
        guard case .wide(var state) = navigation, !state.home, case .session(let session) = state.main else { return }
        if state.beside == .preview {
            state.beside = nil
        } else {
            if livePreviews[session.id] == nil { livePreviews[session.id] = LivePreview() }
            state.beside = .preview
        }
        navigation = .wide(state)
    }

    var livePreviewOpen: Bool { beside == .preview }

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
