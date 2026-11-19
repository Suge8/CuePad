#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CueStore
import WebKit

/// 网页要的系统界面：选文件（只 Mac 要接，iOS 的网页视图自己弹）、alert、confirm、prompt、开新窗口。WKWebView 没有 UI 代理时这些全不做：macOS 上文件框点了没反应，
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

    #if os(macOS)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        // Agent 交的文件（`cuepad live upload`）：这一下是它点的，不弹面板
        if let files = agent.upload {
            agent.upload = nil
            return files
        }
        return await FilePicker.web(multiple: parameters.allowsMultipleSelection, folders: parameters.allowsDirectories)
    }
    #endif

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
        if LiveAddress.isLocal(url) { webView.load(navigationAction.request) } else { Self.openOutside(url) }
        return nil
    }

    /// Agent 的动作弹出来的、又没人看着这一页（没开在面板里）：当场答掉——alert 点确定，confirm、prompt 当取消，不让页面停在那一句上。
    /// 都记进控制台（`cuepad live console` 与动作回执里看得到）。
    private func ask(_ kind: PageAsk.Kind, _ message: String, from frame: WKFrameInfo, text: String = "") async -> String? {
        let origin = frame.securityOrigin
        let shown = origin.host.isEmpty ? web.url.map(LiveAddress.shown) ?? "" : origin.host + (origin.port == 0 ? "" : ":\(origin.port)")
        #if os(macOS)
        let said = "\(kind.shown)「\(message)」"
        if agent.acting, panes == 0 {
            record.note("dialog", said + (kind == .alert ? "：没人看着这一页，点了确定" : "：没人看着这一页，答了取消"))
            return nil
        }
        record.note("dialog", said + "：在等用户在预览里回答，答完之前这一页读不了也点不了")
        #endif
        return await withCheckedContinuation { reply in
            asks.append(PageAsk(kind: kind, origin: shown, message: message, text: text) { reply.resume(returning: $0) })
        }
    }

    /// 默认浏览器（Mac）、Safari（手机、iPad）。
    static func openOutside(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
