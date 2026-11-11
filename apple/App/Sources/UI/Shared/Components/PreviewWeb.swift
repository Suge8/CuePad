import CueStore
import CueText
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// 脚本可以跑（演示页常带图表与交互），但一切联网与读别的文件的请求都被拦掉（`PreviewWebGuard`），页内链接不跳转。拦截规则没能装上时不打开页面，不退回到不设防。
/// 每个视图自己建一个 WKWebView 载入：全屏页的翻页会给同一页重建视图，SwiftUI 的 `WebView` 不许两个视图共用一个 `WebPage`
/// （同一组两份网页左右翻时曾因此崩溃）。WebKit 载不出来（文稿坏了、这台转不了）时同文件不在本机一样写读不了，不留一张白页或 WebKit 的报错码。
struct PreviewWeb: View {
    let file: URL
    @State private var rules: WKContentRuleList?
    @State private var failure: String?
    @State private var unreadable = false
    #if os(macOS)
    @Environment(\.previewFlight) private var flight
    #endif

    var body: some View {
        Group {
            if let rules {
                // 读不了时盖在藏起的页面上，不换掉页面：在全屏页的分页里换掉，WebKit 的视图不会被撤走，它铺的报错还露在下面（模拟器实测）
                OfflineWebView(file: file, rules: rules, unreadable: $unreadable).ignoresSafeArea(.container, edges: OfflineWebView.edges)
                    .overlay { if unreadable { EmptyState(mascot: .error, title: "读不了这个文件").padding(Spacing.page) } }
            } else if let failure {
                EmptyState(mascot: .error, title: "没法安全地打开这个页面", message: .verbatim(failure)).padding(Spacing.page).frame(maxHeight: .infinity)
            } else {
                #if os(iOS)
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
            } catch {
                failure = error.localizedDescription
                #if os(macOS)
                flight?.pagePainted()
                #endif
            }
        }
    }
}

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

    static func allows(_ type: WKNavigationType, to url: URL?) -> Bool {
        type == .other || url?.fragment != nil && url?.scheme == "about"
    }

    /// 网页按内容载入（about:blank 上，读不到任何文件）；别的类型（文稿）按文件载入，WebKit 才转成页面，给它一段字节只会把字节铺出来。
    static func loadsByContent(_ file: URL) -> Bool { PreviewKind(fileName: file.lastPathComponent) == .web }

    static func mimeType(of file: URL) -> String { AttachmentKey.type(ofName: file.lastPathComponent)?.preferredMIMEType ?? "text/html" }

    /// 不上屏的渲染用 `WebPage`（没有视图也能导出画面）；上屏的是 `OfflineWebView`。
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

private struct OfflineWebView {
    let file: URL
    let rules: WKContentRuleList
    @Binding var unreadable: Bool

    func makeCoordinator() -> Coordinator { Coordinator(unreadable: $unreadable) }

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
        private let unreadable: Binding<Bool>
        private var finished = false

        init(unreadable: Binding<Bool>) { self.unreadable = unreadable }

        deinit {
            loading?.cancel()
            painting?.cancel()
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            PreviewWebGuard.allows(action.navigationType, to: action.request.url) ? .allow : .cancel
        }

        /// 载完后等页面真画上一帧才换下占位（手机盖着的缩略图，Mac 飞来停着的快照，`painted`）：didFinish 时 WebKit 还没画，
        /// 当场撤占位会露出几帧空白（模拟器逐帧录屏实测四帧）。页面再画两帧（脚本画的图表、字体落定；藏着时帧可能不来，最多等 300ms，
        /// 同 `PageSnapshots`），App 这边再提交一帧。
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = true
            painting = Task { [weak self, weak webView] in
                _ = try? await webView?.callAsyncJavaScript(
                    "await new Promise(done => { requestAnimationFrame(() => requestAnimationFrame(done)); setTimeout(done, 300) })",
                    contentWorld: .page)
                await NextFrame.wait()
                self?.painted()
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { fail(webView) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { fail(webView) }

        /// 自己装载的那一次没载出来：WebKit 会在页上铺一行它的报错（如"OfficeImportErrorDomain 错误 912"），藏起页面、换成读不了
        private func fail(_ webView: WKWebView) {
            painted()
            guard !finished else { return }
            webView.isHidden = true
            unreadable.wrappedValue = true
        }

        var painting: Task<Void, Never>?

        #if os(iOS)
        var cover: UIView?

        private func painted() {
            cover?.removeFromSuperview()
            cover = nil
        }
        #else
        weak var flight: PreviewFlight?
        /// 画上第一帧之前透明（`makeNSView`）：翻页翻到网页时 WebKit 先铺一整页白底，深色下是一下白闪
        weak var view: WKWebView?

        private func painted() {
            view?.alphaValue = 1
            flight?.pagePainted(view)
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
        switch PreviewKind(fileName: file.lastPathComponent) {
        case .document, .spreadsheet: self = .reflow
        case .presentation: self = .fit
        default: return nil
        }
    }

    private static let zoom = 1.3

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
    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.flight = context.environment.previewFlight
        let view = make(context.coordinator)
        // 透明着照样排版、出帧（藏起来就不出帧了），画上第一帧再显出来（`Coordinator.painted`）
        view.alphaValue = 0
        context.coordinator.view = view
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
/// 载完之前盖着缩略图的画面（`previewLook`），从缩略图飞出来的第一帧就有图（网页的是桌面宽的首屏、文稿的是纸面，与重排后的页不一样，只当占位）。
extension OfflineWebView: UIViewRepresentable {
    static let edges = Edge.Set.all
    func makeUIView(context: Context) -> WKWebView {
        let view = make(context.coordinator)
        // 垫桌面色、盖住整页：页面画出一部分时不从缩略图四周露出来（两层字）
        let cover = PreviewCover(look: context.environment.previewLook, ground: UIColor(context.environment.palette.desk))
        cover.frame = view.bounds
        cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(cover)
        context.coordinator.cover = cover
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { view.scrollView.previewInsets(context.environment.previewInsets) }
}
#endif
