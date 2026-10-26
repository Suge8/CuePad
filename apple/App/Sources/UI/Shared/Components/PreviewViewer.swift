import CueStore
import SwiftUI

/// 点开的那一份，和与它同一组的几份（全屏页里左右翻）；`group` 认它从哪张缩略图放大（`PreviewZoomKey`）。
/// `reply` 是底栏对谁说，nil 时照挂全屏页的那一页（`previewPresenter` 的 `reply`），只有拍板卡另给（那几个选项）。
/// `looks`：提问点名的图各看什么（`CueShown`），有的话页顶写它，不写标题。
struct PreviewOpening: Identifiable, Equatable {
    let preview: PiPreview
    let batch: [PiPreview]
    let group: String
    var reply: PreviewReply?
    var looks: [UUID: String] = [:]

    var id: UUID { preview.id }

    func index(of current: UUID) -> Int { batch.firstIndex { $0.id == current } ?? 0 }

    func title(of preview: PiPreview) -> String { looks[preview.id] ?? preview.title }

    /// "2 / 3 · 图片"，只有一份时只写类型
    func position(at index: Int) -> Dotted { Dotted(batch.count > 1 ? "\(index + 1) / \(batch.count)" : nil, batch[index].kind?.label) }
}

/// 全屏页底栏：Cue 页上是对 Cue 说，会话页上是对这个会话说，拍板卡点开的是那几个选项。
enum PreviewReply: Equatable {
    case cue
    case session(PiSessionState)
    case answer(CueMessage)
}

/// 挂着全屏页的那一页交给页里的缩略图（如你的话里带的图片 `ChatImages`）：点一张就从这里打开，不各挂一个。
struct PreviewOpener {
    let open: @MainActor (PreviewOpening) -> Void
    func callAsFunction(_ opening: PreviewOpening) { open(opening) }
}

extension EnvironmentValues {
    @Entry var openPreview: PreviewOpener?
    /// 全屏页的顶栏、底栏（手机上还有状态栏）占的边：页铺满全屏页，没放大的内容排在这几条边之内，会滚、放大了的内容从栏后面透出来。
    @Entry var previewInsets = EdgeInsets()
}

/// 全屏页里图的缩放，两端同一套。
enum PreviewScale {
    /// 双击（Mac 还有智能缩放）放大到适合屏幕的这么多倍
    static let tap: CGFloat = 2.5

    /// 放大后换上的那张清楚的要解多大（最长边像素）：适合屏幕时铺的像素（`fit`）× 最多放大的倍数（`most`）——放到最大时一个图像素
    /// 对一个屏幕像素，再多也看不出——夹在原图（`original`）以内、不过 `detailCap`。两端都只在第一次放大停下来才解它，只看不放大的图不解。
    nonisolated static func detailPixels(fit: CGFloat, most: CGFloat, original: CGSize) -> Int {
        Int(min(fit * most, max(original.width, original.height), CGFloat(detailCap)).rounded(.up))
    }

    /// 清楚的那张最长边至多这么多：一张至多 8192² × 4 字节（256MB）
    nonisolated static let detailCap = 8192
}

/// 一个文件的内容：网页与 Markdown 两端一样，其余每类怎么显示在各端的 `PreviewPage`。
struct PreviewContent: View {
    let preview: PiPreview
    let file: URL?
    /// 是不是翻到的这一页（翻页留着的邻页不是）
    var active = true
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let file {
                switch preview.kind {
                case .web: PreviewWeb(file: file)
                case .markdown: PreviewMarkdown(file: file)
                default: PreviewPage(preview: preview, file: file, active: active)
                }
            } else {
                EmptyState(mascot: .error, title: "读不了这个文件").padding(24).frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.desk)
    }
}

private struct PreviewMarkdown: View {
    let file: URL
    @State private var text: String?

    var body: some View {
        ScrollView {
            MarkdownText(source: text ?? "").padding(20).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }
        .task { text = (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
    }
}
