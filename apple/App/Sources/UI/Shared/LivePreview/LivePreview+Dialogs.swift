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
    struct PageAsk: Identifiable {
        enum Kind { case alert, confirm, prompt }

        let id = UUID()
        let kind: Kind
        let origin: String
        let message: String
        var text: String
        fileprivate let reply: (String?) -> Void
    }

    func answer(_ id: PageAsk.ID, _ value: String?) {
        guard let index = asks.firstIndex(where: { $0.id == id }) else { return }
        asks.remove(at: index).reply(value)
    }

    #if os(macOS)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
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

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if LiveAddress.isLocal(url) { webView.load(navigationAction.request) } else { Self.openOutside(url) }
        return nil
    }

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

    static func openOutside(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
