#if os(iOS) && DEBUG
import Network
import SwiftUI
import WebKit

/// 网页预览原型（issue #79 第 1 项，只在 spike 分支）：`-CuePadScene livepreview`。
/// 手机 WKWebView → App 内入口（HTTP CONNECT 代理、SOCKS5 代理或回环端口映射）→ 通道（每个授权端口一个手机本机 TCP 端点）→ Mac → dev server 与它的后端。
/// 代理按 CONNECT/SOCKS 的目标分流：localhost 上的授权端口走通道，localhost 上别的端口拒绝，其余主机走手机自己的网络。
/// 通道：`-LPChannel host:port`（默认 127.0.0.1:19000，第 1 步的 Mac 网关，只代表 5173）；`-LPIroh <ticket>` 时 dlopen `-LPIrohLib` 的 Rust 隧道库（spike/cuetunnel），
/// 为 `-LPPorts`（默认 5173）里每个端口要一个手机回环端口；`-LPIrohRelayOnly YES` 只走中继。
/// `-LPCases mode@url,…`：依次开新的 WebView（各自独立的非持久数据存储）加载，记下代理收到的目标、导航结果、页面事件；最后一个留着不关（量 HMR）。
/// 日志写标准错误（app-sim.log），每行 `LP <毫秒时间戳> …`。
struct LivePreviewSpike: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .systemBackground
        Task { await LivePreviewRunner(host: host).run() }
        return host
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

nonisolated enum LPLog {
    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static func line(_ text: String) {
        FileHandle.standardError.write(Data("LP \(now()) \(text)\n".utf8))
    }
}

@MainActor
final class LivePreviewRunner: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let host: UIView
    private var webView: WKWebView?
    private var finished: CheckedContinuation<String, Never>?
    private var loadStarted: Int64 = 0
    private var generation = 0
    private var proxies: [LPProxyServer] = []

    init(host: UIView) { self.host = host }

    private static let defaults = UserDefaults.standard
    private static let instrument = """
    (() => {
      const post = (type, extra = {}) => { try { webkit.messageHandlers.lp.postMessage(JSON.stringify({type, t: Date.now(), href: location.href, ...extra})) } catch (e) {} };
      const WS = window.WebSocket;
      const Wrapped = function (url, protocols) {
        const ws = protocols === undefined ? new WS(url) : new WS(url, protocols);
        post('ws-new', {url: String(url), protocols: String(protocols)});
        ws.addEventListener('open', () => post('ws-open', {url: String(url), protocol: ws.protocol}));
        ws.addEventListener('close', e => post('ws-close', {url: String(url), code: e.code, reason: e.reason}));
        ws.addEventListener('error', () => post('ws-error', {url: String(url)}));
        ws.addEventListener('message', e => post('ws-msg', {data: String(e.data).slice(0, 160)}));
        return ws;
      };
      Wrapped.prototype = WS.prototype;
      Object.assign(Wrapped, {CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3});
      window.WebSocket = Wrapped;
      const signature = () => (document.querySelector('h1')?.textContent ?? '') + '|' + (document.querySelector('#api')?.textContent ?? '') + '|' + [...document.querySelectorAll('style')].map(s => s.textContent.length).join(',');
      addEventListener('load', () => {
        const n = performance.getEntriesByType('navigation')[0];
        post('load', {timeOrigin: Math.round(performance.timeOrigin), ttfb: n && Math.round(n.responseStart), dcl: n && Math.round(n.domContentLoadedEventEnd), resources: performance.getEntriesByType('resource').length, sig: signature(), title: document.title});
        let last = signature();
        new MutationObserver(() => { const s = signature(); if (s !== last) { last = s; post('changed', {sig: s}) } })
          .observe(document.documentElement, {subtree: true, childList: true, characterData: true});
      });
      addEventListener('error', e => post('js-error', {msg: String(e.message)}));
      post('script-start');
    })();
    """

    func run() async {
        let channel = await Self.channels()
        let cases = (Self.defaults.string(forKey: "LPCases") ?? "connect@http://localhost:5173/")
            .split(separator: ",").map { String($0) }
        LPLog.line("suite channels=\(channel) cases=\(cases.count)")
        for (index, item) in cases.enumerated() {
            let parts = item.split(separator: "@", maxSplits: 1).map(String.init)
            let result = await load(mode: parts[0], url: URL(string: parts[1])!, channel: channel)
            LPLog.line("case-result #\(index) \(item) => \(result)")
            if index < cases.count - 1 {
                // 给页面里的 WebSocket、懒加载资源一点时间把连接打出来，代理日志才完整
                try? await Task.sleep(for: .seconds(2))
                tearDown()
            }
        }
        await reloads()
        LPLog.line("suite-done")
    }

    /// Mac 上每个被授权端口在手机这边的样子：一个 TCP 端点。
    private static func channels() async -> [UInt16: NWEndpoint] {
        if let ticket = defaults.string(forKey: "LPIroh") {
            let lib = defaults.string(forKey: "LPIrohLib") ?? "/Users/sugeh/Project/CuePad-wt/preview-spike/spike/cuetunnel/target/aarch64-apple-ios-sim/release/libcuetunnel.dylib"
            let ports = (defaults.string(forKey: "LPPorts") ?? "5173").split(separator: ",").compactMap { UInt16($0) }
            return await LPIroh.start(library: lib, ticket: ticket, relayOnly: defaults.bool(forKey: "LPIrohRelayOnly"), ports: ports)
        }
        let spec = (defaults.string(forKey: "LPChannel") ?? "127.0.0.1:19000").split(separator: ":")
        return [5173: .hostPort(host: NWEndpoint.Host(String(spec[0])), port: NWEndpoint.Port(String(spec[1]))!)]
    }

    private func load(mode: String, url: URL, channel: [UInt16: NWEndpoint]) async -> String {
        let configuration = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        var target = url
        switch mode {
        case "connect", "socks":
            let proxy = LPProxyServer(kind: mode == "connect" ? .connect : .socks, channels: channel)
            let port = await proxy.start()
            proxies.append(proxy)
            let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            store.proxyConfigurations = [mode == "connect" ? ProxyConfiguration(httpCONNECTProxy: endpoint) : ProxyConfiguration(socksv5Proxy: endpoint)]
        case "loopback":
            // 回环映射：手机本机 127.0.0.1:<url 的端口> 上监听，每条连接原样接到通道
            let proxy = LPProxyServer(kind: .raw, channels: channel)
            _ = await proxy.start(port: UInt16(url.port ?? 80))
            proxies.append(proxy)
        default:
            target = url
        }
        configuration.websiteDataStore = store
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: Self.instrument, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(self, name: "lp")
        let webView = WKWebView(frame: host.bounds, configuration: configuration)
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.navigationDelegate = self
        webView.isInspectable = true
        host.addSubview(webView)
        self.webView = webView
        loadStarted = LPLog.now()
        LPLog.line("load-start mode=\(mode) url=\(target.absoluteString)")
        return await navigate { webView.load(URLRequest(url: target)) }
    }

    private func navigate(_ start: () -> Void) async -> String {
        generation += 1
        let mine = generation
        return await withCheckedContinuation { continuation in
            finished = continuation
            start()
            Task {
                try? await Task.sleep(for: .seconds(15))
                if self.generation == mine { self.finish("timeout") }
            }
        }
    }

    /// 同一个 WebView 里再刷新几次：去掉新建 WebContent 进程的那一截，看热的首屏
    private func reloads() async {
        let count = Self.defaults.integer(forKey: "LPReloads")
        for index in 0..<count {
            try? await Task.sleep(for: .seconds(1))
            loadStarted = LPLog.now()
            let result = await navigate { _ = webView?.reloadFromOrigin() }
            LPLog.line("reload #\(index) => \(result)")
        }
    }

    private func finish(_ result: String) {
        guard let continuation = finished else { return }
        finished = nil
        continuation.resume(returning: result)
    }

    private func tearDown() {
        webView?.removeFromSuperview()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "lp")
        webView = nil
        proxies.forEach { $0.stop() }
        proxies = []
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        LPLog.line("nav-finish +\(LPLog.now() - loadStarted)ms url=\(webView.url?.absoluteString ?? "-")")
        finish("finished +\(LPLog.now() - loadStarted)ms")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        let ns = error as NSError
        LPLog.line("nav-fail-provisional \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        finish("failed \(ns.domain) \(ns.code)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        let ns = error as NSError
        LPLog.line("nav-fail \(ns.domain) \(ns.code) \(ns.localizedDescription)")
        finish("failed \(ns.domain) \(ns.code)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse {
            LPLog.line("nav-response status=\(http.statusCode) url=\(http.url?.absoluteString ?? "-")")
        }
        return .allow
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        LPLog.line("js \(message.body)")
    }
}

/// Rust 隧道库（iroh）的入口：两个 C 函数，模拟器里直接 dlopen 宿主上的 dylib（真机要把静态库编进包）。
nonisolated enum LPIroh {
    typealias Connect = @convention(c) (UnsafePointer<CChar>, Bool) -> Bool
    typealias Forward = @convention(c) (UInt16) -> UInt16

    static func start(library: String, ticket: String, relayOnly: Bool, ports: [UInt16]) async -> [UInt16: NWEndpoint] {
        let began = LPLog.now()
        // 连上要几秒（端点上线、找中继），放到后台线程；C 函数指针不是 Sendable，在那边再取一次符号
        let connected = await Task.detached { connect(library: library, ticket: ticket, relayOnly: relayOnly) }.value
        LPLog.line("iroh connected=\(connected) +\(LPLog.now() - began)ms")
        guard connected, let forward = dlsym(dlopen(library, RTLD_NOW), "cuetunnel_forward") else { return [:] }
        var channels: [UInt16: NWEndpoint] = [:]
        for port in ports {
            let local = unsafeBitCast(forward, to: Forward.self)(port)
            LPLog.line("iroh mac:\(port) -> 127.0.0.1:\(local)")
            channels[port] = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: local)!)
        }
        return channels
    }

    private static func connect(library: String, ticket: String, relayOnly: Bool) -> Bool {
        guard let handle = dlopen(library, RTLD_NOW), let symbol = dlsym(handle, "cuetunnel_connect") else {
            LPLog.line("iroh dlopen failed \(String(cString: dlerror()))")
            return false
        }
        return ticket.withCString { unsafeBitCast(symbol, to: Connect.self)($0, relayOnly) }
    }
}
#endif
