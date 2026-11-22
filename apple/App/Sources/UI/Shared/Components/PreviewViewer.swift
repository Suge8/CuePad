import CueStore
import SwiftUI

struct PreviewOpening: Identifiable, Equatable {
    let preview: PreviewItem
    let batch: [PreviewItem]
    let group: String
    var reply: PreviewReply?
    var looks: [UUID: String] = [:]

    var id: UUID { preview.id }

    var entry: UUID? { UUID(uuidString: group) }

    func index(of current: UUID) -> Int { batch.firstIndex { $0.id == current } ?? 0 }

    func title(of preview: PreviewItem) -> String { looks[preview.id] ?? preview.title }

    func neighbor(of current: UUID, step: Int) -> UUID? {
        let next = index(of: current) + step
        return batch.indices.contains(next) ? batch[next].id : nil
    }

    func position(at index: Int) -> Dotted { Dotted(batch.count > 1 ? "\(index + 1) / \(batch.count)" : nil, batch[index].kind?.label) }
}

enum PreviewReply: Equatable {
    case cue
    case session(SessionState)
}

struct PreviewOpener: Equatable {
    let owner: ObjectIdentifier
    let open: @MainActor (PreviewOpening) -> Void
    nonisolated static func == (a: Self, b: Self) -> Bool { a.owner == b.owner }
    func callAsFunction(_ opening: PreviewOpening) { open(opening) }
}

extension EnvironmentValues {
    @Entry var openPreview: PreviewOpener?
    @Entry var previewInsets = EdgeInsets()
}

enum PreviewScale {
    static let tap: CGFloat = 2.5

    nonisolated static func detailPixels(fit: CGFloat, most: CGFloat, original: CGSize) -> Int {
        Int(min(fit * most, max(original.width, original.height), CGFloat(detailCap)).rounded(.up))
    }

    nonisolated static let detailCap = 8192
}

struct PreviewContent: View {
    static let measure: CGFloat = 680
    /// Mac 全屏页最大这么大，就是网页缩略图排首屏的大小（`PageSnapshots`：不挂视图的 `WebPage` 固定按 1024×768 排，没有接口改，实测）：
    /// 窗口放得下整页时，飞来的那张与真网页是同一种排法，落地不跳。
    static let page = CGSize(width: 1024, height: 768)

    let preview: PreviewItem
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
                PreviewUnreadable()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DeliverableLooks.drawn(preview.kind) ? palette.paper : palette.desk)
    }
}

private struct PreviewMarkdown: View {
    let file: URL

    var body: some View {
        PreviewTextFile(file: file, parse: { $0 }) { text in
            ScrollView {
                MarkdownText(source: text, style: .document).padding(Spacing.panel).frame(maxWidth: PreviewContent.measure, alignment: .leading).frame(maxWidth: .infinity)
            }
        }
    }
}

struct PreviewUnreadable: View {
    var body: some View {
        EmptyState(mascot: .error, title: "读不了这个文件").padding(Spacing.page).frame(maxHeight: .infinity)
    }
}

nonisolated enum PreviewFile {
    static func text(of file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }

    @concurrent static func read<Value: Sendable>(_ file: URL, _ parse: @Sendable (String) -> Value) async throws -> Value { parse(try text(of: file)) }
}

struct PreviewTextFile<Value: Sendable, Content: View>: View {
    let file: URL
    let parse: @Sendable (String) -> Value
    @ViewBuilder let content: (Value) -> Content
    @State private var value: Value?
    @State private var failed = false

    var body: some View {
        Group {
            if let value {
                content(value)
            } else if failed {
                PreviewUnreadable()
            } else {
                Color.clear
            }
        }
        .task(id: file) {
            do {
                value = try await PreviewFile.read(file, parse)
                failed = false
            } catch {
                value = nil
                failed = true
            }
        }
    }
}
