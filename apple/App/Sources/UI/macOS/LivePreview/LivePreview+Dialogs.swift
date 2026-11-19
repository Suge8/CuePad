#if os(macOS)
import AppKit
import CueStore
import WebKit

/// 网页要的系统界面：选文件、alert、confirm、prompt、开新窗口。WKWebView 没有 UI 代理时这些全不做：macOS 上文件框点了没反应，
/// alert 直接过去，confirm 当取消、prompt 当空，`window.open` 与 `target=_blank` 什么也不开。
extension LivePreview: WKUIDelegate {
    /// 网页弹的一句（alert、confirm、prompt）：排着队，预览面板一次给你看一个（`LivePreviewPane`）。等着的时候网页的脚本停在那一句上。
    struct PageAsk: Identifiable {
        enum Kind { case alert, confirm, prompt }

        let id = UUID()
        let kind: Kind
        /// 哪个网站在说话（`主机:端口`）：内容是网页定的，不是 CuePad 说的。
        let origin: String
        let message: String
        var text: String
        fileprivate let reply: (String?) -> Void
    }

    /// 答掉这一句：nil 是取消（点外面、Esc 也是）。已答过的不再答。
    func answer(_ id: PageAsk.ID, _ value: String?) {
        guard let index = asks.firstIndex(where: { $0.id == id }) else { return }
        asks.remove(at: index).reply(value)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        await FilePicker.web(multiple: parameters.allowsMultipleSelection, folders: parameters.allowsDirectories)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        _ = await ask(.alert, message, from: frame)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await ask(.confirm, message, from: frame) != nil
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        await ask(.prompt, prompt, from: frame, text: defaultText ?? "")
    }

    /// `window.open` 与 `target=_blank`：不另开网页视图（`window.open` 拿到 null）。本机的页在这块预览里接着开，是这个会话在做的东西，
    /// 登录状态也在这份数据存储里；别处的（文档、GitHub、登录提供方）交给默认浏览器，预览不被带离会话的服务（`watch` 只认会话的地址）。
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if Self.local(url, beside: webView.url) { webView.load(navigationAction.request) } else { NSWorkspace.shared.open(url) }
        return nil
    }

    /// 本机：回环地址，或与此刻页面同一台主机（局域网地址、`.local` 起的开发服务）。
    private static func local(_ url: URL, beside page: URL?) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host.hasPrefix("127.") || host == page?.host(percentEncoded: false)?.lowercased()
    }

    private func ask(_ kind: PageAsk.Kind, _ message: String, from frame: WKFrameInfo, text: String = "") async -> String? {
        let origin = frame.securityOrigin
        let shown = origin.host.isEmpty ? web.url.map(LiveAddress.shown) ?? "" : origin.host + (origin.port == 0 ? "" : ":\(origin.port)")
        return await withCheckedContinuation { reply in
            asks.append(PageAsk(kind: kind, origin: shown, message: message, text: text) { reply.resume(returning: $0) })
        }
    }
}
#endif
