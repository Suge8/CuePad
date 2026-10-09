import CueStore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// 预览文件在本机的可读位置：附件目录里的文件以哈希为名，没有扩展名，系统的快速查看与"存到文件"认不出类型，
/// 所以按原文件名放一份（缓存目录里，同卷克隆不占额外空间，系统可随时清理）。
nonisolated enum PreviewFile {
    static func url(for preview: PiPreview, original: URL) -> URL? {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "CuePadPreviews", directoryHint: .isDirectory).appending(path: preview.hash, directoryHint: .isDirectory)
        // 记录来自同步：文件名不能带路径
        let target = directory.appending(path: preview.name.replacing("/", with: "_").replacing("..", with: "_"))
        guard !FileManager.default.fileExists(atPath: target.path) else { return target }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: original, to: target)
            return target
        } catch {
            return nil
        }
    }
}

extension View {
    /// 点预览卡后的全屏预览：网页与 Markdown 在 CuePad 自己的页里（网页只读、不联网），图片、PDF、文本交给系统的快速查看（缩放、翻页、分享都有）。
    /// 一个对话只在这里挂一次，不在每张卡上各挂一个。
    func previewPresenter(_ opened: Binding<PiPreview?>) -> some View { modifier(PreviewPresenter(opened: opened)) }
}

private struct PreviewPresenter: ViewModifier {
    @Binding var opened: PiPreview?
    @Environment(AppServices.self) private var services
    @State private var quickLook: URL?

    private var own: Binding<PiPreview?> {
        Binding { opened.flatMap { $0.kind == .web || $0.kind == .markdown ? $0 : nil } } set: { opened = $0 }
    }

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .fullScreenCover(item: own) { PreviewPage(preview: $0, file: file(of: $0)) }
            #else
            .sheet(item: own) { PreviewPage(preview: $0, file: file(of: $0)).frame(minWidth: 760, minHeight: 560) }
            #endif
            .quickLookPreview($quickLook)
            .onChange(of: opened) { _, preview in
                guard let preview, own.wrappedValue == nil else { return }
                quickLook = file(of: preview)
                opened = nil
            }
    }

    private func file(of preview: PiPreview) -> URL? {
        services.store.files.fileURL(for: preview.hash).flatMap { PreviewFile.url(for: preview, original: $0) }
    }
}

/// 网页与 Markdown 的全屏页：一条顶栏（关闭、标题、分享到文件），下面是内容。
private struct PreviewPage: View {
    let preview: PiPreview
    let file: URL?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("关闭") { dismiss() }
                Text(preview.title).font(.headline).foregroundStyle(palette.ink).lineLimit(1).frame(maxWidth: .infinity)
                if let file { ShareLink(item: file) { Image(systemName: "square.and.arrow.up") } } else { Color.clear.frame(width: 24) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if let file {
                switch preview.kind {
                case .markdown: PreviewMarkdown(file: file)
                default: PreviewWeb(file: file)
                }
            } else {
                ContentUnavailableView("读不了这个文件", systemImage: "exclamationmark.triangle").frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.desk)
    }
}

private struct PreviewMarkdown: View {
    let file: URL
    @State private var text: String?
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            MarkdownText(source: text ?? "").padding(20).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }
        .task { text = (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
    }
}

/// 网页的只读离线渲染：脚本可以跑（演示页常带图表与交互），但一切联网与读别的文件的请求都被拦掉（只放行 data:、blob:、about:），
/// 页内链接不跳转。拦截规则没能装上时不打开页面，不退回到不设防。
private struct PreviewWeb: View {
    let file: URL
    @State private var rules: WKContentRuleList?
    @State private var failure: String?

    var body: some View {
        Group {
            if let rules {
                PreviewWebHost(file: file, rules: rules).ignoresSafeArea(.container, edges: .bottom)
            } else if let failure {
                ContentUnavailableView("没法安全地打开这个页面", systemImage: "lock.trianglebadge.exclamationmark", description: Text(failure))
            } else {
                ProgressView()
            }
        }
        .task {
            do { rules = try await PreviewWebGuard.rules() } catch { failure = error.localizedDescription }
        }
    }
}

/// 网页预览的防护：脚本照跑，联网与读别的文件一律拦掉，页内链接不跳转。
enum PreviewWebGuard {
    private static let blockEverythingButInline = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}]
        """

    static func rules() async throws -> WKContentRuleList {
        guard let list = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "cuepad.preview.offline", encodedContentRuleList: blockEverythingButInline)
        else { throw CocoaError(.featureUnsupported) }
        return list
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            // 只放行我们自己装载的那一次；点链接（含跳到别的页面）一律不动，页内锚点除外
            if action.navigationType == .other { return .allow }
            return action.request.url?.fragment != nil && action.request.url?.scheme == "about" ? .allow : .cancel
        }
    }

    static func makeWebView(file: URL, rules: WKContentRuleList, delegate: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rules)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = delegate
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "text/html"
        if let data = try? Data(contentsOf: file) {
            web.load(data, mimeType: type, characterEncodingName: "utf-8", baseURL: URL(string: "about:blank")!)
        }
        return web
    }
}

#if os(iOS)
private struct PreviewWebHost: UIViewRepresentable {
    let file: URL
    let rules: WKContentRuleList
    func makeCoordinator() -> PreviewWebGuard.Coordinator { PreviewWebGuard.Coordinator() }
    func makeUIView(context: Context) -> WKWebView { PreviewWebGuard.makeWebView(file: file, rules: rules, delegate: context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
private struct PreviewWebHost: NSViewRepresentable {
    let file: URL
    let rules: WKContentRuleList
    func makeCoordinator() -> PreviewWebGuard.Coordinator { PreviewWebGuard.Coordinator() }
    func makeNSView(context: Context) -> WKWebView { PreviewWebGuard.makeWebView(file: file, rules: rules, delegate: context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif
