import CueStore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// 网页的只读离线渲染（手机上还有文稿、表格、演示文稿：WebKit 按文件类型把它们转成页面）：脚本可以跑（演示页常带图表与交互），
/// 但一切联网与读别的文件的请求都被拦掉（`PreviewWebGuard`），页内链接不跳转。拦截规则没能装上时不打开页面，不退回到不设防。
/// 每个视图自己建一个 WKWebView 载入：全屏页的翻页会给同一页重建视图，SwiftUI 的 `WebView` 不许两个视图共用一个 `WebPage`
/// （同一组两份网页左右翻时曾因此崩溃）。
struct PreviewWeb: View {
    let file: URL
    @State private var rules: WKContentRuleList?
    @State private var failure: String?

    var body: some View {
        Group {
            if let rules {
                OfflineWebView(file: file, rules: rules).ignoresSafeArea(.container, edges: OfflineWebView.edges)
            } else if let failure {
                EmptyState(mascot: .error, title: "没法安全地打开这个页面", message: .verbatim(failure)).padding(24).frame(maxHeight: .infinity)
            } else {
                #if os(iOS)
                // 规则还在装时就铺缩略图的画面，与载入时盖在页面上的那张同一处（`OfflineWebView`）
                PreviewCoverView().ignoresSafeArea(.container, edges: OfflineWebView.edges)
                #else
                Spinner(.regular)
                #endif
            }
        }
        .task {
            do {
                rules = try await PreviewWebGuard.rules()
                DebugHooks.previewWebLoaded(file)
            } catch { failure = error.localizedDescription }
        }
    }
}

/// 网页预览的防护（全屏页与缩略图快照共用）：脚本照跑，联网与读别的文件一律拦掉，页内链接不跳转。
/// 放行的只有页内的 data:、blob:、about:，文稿按文件打开时的那一个文件（读权限也只给它），与 WebKit 把文稿转成页面时生成的页内资源（x-apple-ql-id:）。
enum PreviewWebGuard {
    private static let blockEverythingButInline = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^file:","resource-type":["document"]},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^x-apple-ql-id"},"action":{"type":"ignore-previous-rules"}}]
        """

    static let blank = URL(string: "about:blank")!

    /// 拦截规则；装不上就抛出，没有"不设防"的退路。
    static func rules() async throws -> WKContentRuleList {
        guard let rules = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "cuepad.preview.offline", encodedContentRuleList: blockEverythingButInline)
        else { throw CocoaError(.featureUnsupported) }
        return rules
    }

    /// 只放行我们自己装载的那一次；点链接（含跳到别的页面）一律不动，页内锚点除外。
    static func allows(_ type: WKNavigationType, to url: URL?) -> Bool {
        type == .other || url?.fragment != nil && url?.scheme == "about"
    }

    /// 网页按内容载入（about:blank 上，读不到任何文件）；别的类型（文稿）按文件载入，WebKit 才转成页面，给它一段字节只会把字节铺出来。
    static func loadsByContent(_ file: URL) -> Bool { PiPreviewKind(fileName: file.lastPathComponent) == .web }

    static func mimeType(of file: URL) -> String { UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "text/html" }

    /// 不显示的网页（缩略图快照 `PageSnapshots` 与调试快照）：装好规则、载入这个文件，载入完才返回。不上屏的渲染用 `WebPage`
    /// （没有视图也能导出画面）；上屏的是 `OfflineWebView`。
    static func page(for file: URL) async throws -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(try await rules())
        let page = WebPage(configuration: configuration, navigationDecider: InlineOnly())
        let events = page.load(try await read(file), mimeType: mimeType(of: file), characterEncoding: .utf8, baseURL: blank)
        for try await event in events where event == .finished { break }
        return page
    }

    /// 文件最大 20 MB，读取不占主线程。
    @concurrent static func read(_ file: URL) async throws -> Data { try Data(contentsOf: file) }

    private struct InlineOnly: WebPage.NavigationDeciding {
        func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
            PreviewWebGuard.allows(action.navigationType, to: action.request.url) ? .allow : .cancel
        }
    }
}

/// 全屏页里的那个 WKWebView：装好规则、非持久的数据、只放行自己装载的那一次（`PreviewWebGuard`）。
private struct OfflineWebView {
    let file: URL
    let rules: WKContentRuleList

    func makeCoordinator() -> Coordinator { Coordinator() }

    fileprivate func make(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rules)
        #if os(iOS)
        if let layout = DocumentLayout(file) {
            configuration.userContentController.addUserScript(WKUserScript(source: layout.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        #endif
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .clear
        #endif
        if PreviewWebGuard.loadsByContent(file) {
            let file = file
            coordinator.loading = Task { [weak view] in
                guard let data = try? await PreviewWebGuard.read(file) else { return }
                view?.load(data, mimeType: PreviewWebGuard.mimeType(of: file), characterEncodingName: "utf-8", baseURL: PreviewWebGuard.blank)
            }
        } else {
            view.loadFileURL(file, allowingReadAccessTo: file)
        }
        return view
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loading: Task<Void, Never>?

        deinit { loading?.cancel() }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            PreviewWebGuard.allows(action.navigationType, to: action.request.url) ? .allow : .cancel
        }

        #if os(iOS)
        /// 载完（或载不了）之前盖在页面上的缩略图画面（`PreviewCover`）；拦截规则装好不算载完
        var cover: UIView?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { uncover() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { uncover() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { uncover() }

        private func uncover() {
            cover?.removeFromSuperview()
            cover = nil
        }
        #endif
    }
}

#if os(iOS)
/// 文稿转成的页面怎么贴合屏宽（Mac 上文稿走快速查看）。WebKit 转出来的页按纸面排：Word 是 600 宽的一页、12px 的字，RTF 与表格没写视口、按 980 宽排，
/// 演示文稿是 720 宽的一张张幻灯片（略宽出几像素）——缩到屏宽后字只有七八磅，不放大读不了。
/// - 文稿、表格：按屏宽重排（去掉纸面的固定宽度与留白），字放大到正文大小。
/// - 演示文稿：一页是一张图，按内容实际宽度缩到屏宽，不重排；宽出来的几像素不再让页面横着滚。
private enum DocumentLayout {
    case reflow, fit

    init?(_ file: URL) {
        switch PiPreviewKind(fileName: file.lastPathComponent) {
        case .document, .spreadsheet: self = .reflow
        case .presentation: self = .fit
        default: return nil
        }
    }

    /// 重排后字号放大的倍数：转出来的正文多是 11～12px，放大到约 15px
    private static let zoom = 1.3

    /// 页面载完（文档末尾）时换掉视口；重排还要压掉纸面的版心宽度、最小高度与页边距。
    var script: String {
        let setViewport = """
            document.querySelectorAll('meta[name=viewport]').forEach(meta => meta.remove());
            const viewport = document.createElement('meta');
            viewport.name = 'viewport';
            document.head.appendChild(viewport);
            """
        return switch self {
        case .fit: setViewport + "viewport.content = 'width=' + document.documentElement.scrollWidth;"
        case .reflow:
            setViewport + """
                viewport.content = 'width=device-width, initial-scale=1';
                const style = document.createElement('style');
                style.textContent = 'html{zoom:\(Self.zoom)} body{margin:0;padding:16px} body>div{width:auto!important;max-width:100%!important;min-height:0!important;padding:0!important}';
                document.head.appendChild(style);
                """
        }
    }
}
#endif

#if os(macOS)
extension OfflineWebView: NSViewRepresentable {
    static let edges = Edge.Set.bottom
    func makeNSView(context: Context) -> WKWebView { make(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
/// 手机的全屏页里铺满整屏、滚到两条栏后面，内容边按 `previewInsets` 让出栏；载完之前盖着缩略图的画面（`previewLook`），
/// 从缩略图飞出来的第一帧就有图（网页的是桌面宽的首屏、文稿的是纸面，与重排后的页不一样，只当占位）。
extension OfflineWebView: UIViewRepresentable {
    static let edges = Edge.Set.all
    func makeUIView(context: Context) -> WKWebView {
        let view = make(context.coordinator)
        let cover = PreviewCover(look: context.environment.previewLook)
        cover.frame = view.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(cover)
        context.coordinator.cover = cover
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { view.scrollView.previewInsets(context.environment.previewInsets) }
}
#endif
