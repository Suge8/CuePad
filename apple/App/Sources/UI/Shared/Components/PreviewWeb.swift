import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// 网页的只读离线渲染：脚本可以跑（演示页常带图表与交互），但一切联网与读别的文件的请求都被拦掉（只放行 data:、blob:、about:），
/// 页内链接不跳转。拦截规则没能装上时不打开页面，不退回到不设防。
struct PreviewWeb: View {
    let file: URL
    @State private var page: WebPage?
    @State private var failure: String?

    var body: some View {
        Group {
            if let page {
                WebView(page).ignoresSafeArea(.container, edges: .bottom)
            } else if let failure {
                EmptyState(mascot: .error, title: "没法安全地打开这个页面", message: failure).padding(24).frame(maxHeight: .infinity)
            } else {
                Spinner(.regular)
            }
        }
        .task {
            do {
                let page = try await PreviewWebGuard.page(for: file)
                self.page = page
                DebugHooks.previewWebLoaded(page)
            } catch { failure = error.localizedDescription }
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

    /// 装好拦截规则、开始载入这个文件的网页（`untilLoaded`：等载入完再返回）。规则装不上或文件读不了都抛出，没有"不设防"的退路。
    static func page(for file: URL, untilLoaded: Bool = false) async throws -> WebPage {
        let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "text/html"
        return try await page(loading: try await read(file), mimeType: type, untilLoaded: untilLoaded)
    }

    /// 同一套拦截规则载入一段内容（交付物缩略图拿 Markdown 拼出的页面也走这里，`PageSnapshots`）。
    static func page(loading data: Data, mimeType: String, untilLoaded: Bool = false) async throws -> WebPage {
        guard let rules = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "cuepad.preview.offline", encodedContentRuleList: blockEverythingButInline)
        else { throw CocoaError(.featureUnsupported) }
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rules)
        let page = WebPage(configuration: configuration, navigationDecider: InlineOnly())
        let events = page.load(data, mimeType: mimeType, characterEncoding: .utf8, baseURL: URL(string: "about:blank")!)
        if untilLoaded {
            for try await event in events where event == .finished { break }
        }
        return page
    }

    /// 文件最大 20 MB，读取不占主线程。
    @concurrent private static func read(_ file: URL) async throws -> Data { try Data(contentsOf: file) }

    /// 只放行我们自己装载的那一次；点链接（含跳到别的页面）一律不动，页内锚点除外。
    private struct InlineOnly: WebPage.NavigationDeciding {
        func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
            if action.navigationType == .other { return .allow }
            return action.request.url?.fragment != nil && action.request.url?.scheme == "about" ? .allow : .cancel
        }
    }
}
