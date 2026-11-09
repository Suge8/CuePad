import CueStore
import SwiftUI

/// `reply` 为 nil 时照挂全屏页的那一页（`previewPresenter` 的 `reply`），只有拍板卡另给（那几个选项）。
struct PreviewOpening: Identifiable, Equatable {
    let preview: PiPreview
    let batch: [PiPreview]
    let group: String
    var reply: PreviewReply?
    var looks: [UUID: String] = [:]

    var id: UUID { preview.id }

    /// 这一批在对话里的那一条（`group` 就是它的 id：会话里是 `PiChatEntry.id`，Cue 页是那条消息）；会话底栏的"回复"用它（`PreviewReplyBar`）。
    var entry: UUID? { UUID(uuidString: group) }

    func index(of current: UUID) -> Int { batch.firstIndex { $0.id == current } ?? 0 }

    func title(of preview: PiPreview) -> String { looks[preview.id] ?? preview.title }

    func neighbor(of current: UUID, step: Int) -> UUID? {
        let next = index(of: current) + step
        return batch.indices.contains(next) ? batch[next].id : nil
    }

    func position(at index: Int) -> Dotted { Dotted(batch.count > 1 ? "\(index + 1) / \(batch.count)" : nil, batch[index].kind?.label) }
}

enum PreviewReply: Equatable {
    case cue
    case session(PiSessionState)
    case answer(CueMessage)
}

/// 恒等：给它的全屏页每次更新都新建一个闭包，闭包没法比，不恒等的话读它的每一格缩略图都跟着重算。环境值比出相等时读它的视图留着旧的那一个，所以闭包只能写给它的那一页的状态或绑定（旧的写的也是同一份），不能捕获会变的值。
struct PreviewOpener: Equatable {
    let open: @MainActor (PreviewOpening) -> Void
    nonisolated static func == (a: Self, b: Self) -> Bool { true }
    func callAsFunction(_ opening: PreviewOpening) { open(opening) }
}

extension EnvironmentValues {
    @Entry var openPreview: PreviewOpener?
    @Entry var previewInsets = EdgeInsets()
}

enum PreviewScale {
    static let tap: CGFloat = 2.5

    /// 放大后换上的那张清楚的要解多大（最长边像素）：适合屏幕时铺的像素（`fit`）× 最多放大的倍数（`most`）——放到最大时一个图像素
    /// 对一个屏幕像素，再多也看不出——夹在原图（`original`）以内、不过 `detailCap`。两端都只在第一次放大停下来才解它，只看不放大的图不解。
    nonisolated static func detailPixels(fit: CGFloat, most: CGFloat, original: CGSize) -> Int {
        Int(min(fit * most, max(original.width, original.height), CGFloat(detailCap)).rounded(.up))
    }

    /// 清楚的那张最长边至多这么多：一张至多 8192² × 4 字节（256MB）
    nonisolated static let detailCap = 8192
}

struct PreviewContent: View {
    /// 一行不宽过它，居中；Mac 飞出的落点按它算（`PreviewFlight`）。
    static let measure: CGFloat = 680

    let preview: PiPreview
    let file: URL?
    var active = true
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let file {
                switch preview.kind {
                case .web: PreviewWeb(file: file)
                case .markdown: PreviewMarkdown(file: file)
                case .diff: PreviewDiff(file: file)
                default: PreviewPage(preview: preview, file: file, active: active)
                }
            } else {
                EmptyState(mascot: .error, title: "读不了这个文件").padding(Spacing.page).frame(maxHeight: .infinity)
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
            MarkdownText(source: text ?? "", style: .document).padding(Spacing.panel).frame(maxWidth: PreviewContent.measure, alignment: .leading).frame(maxWidth: .infinity)
        }
        .task { text = (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
    }
}
