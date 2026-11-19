#if os(macOS)
import SwiftUI

/// 栏头在主窗口里常驻，编辑页只把算好的值交到这里，收起时清掉自己的。
@Observable
final class OverlayHeader {
    struct Content: Equatable {
        var page: Workspace.Overlay
        var title: String
        var detail = Dotted()
        /// 灵感编辑页：次要一行画成图形（`EditedLine`），不用 `detail` 与 `widest`。
        var marks: EditedLine.Marks?
        var failed = false
        var help: String?
        /// 次要一行最宽的样子（换上最长的那个状态词）：玻璃按它留宽，状态换字时不伸缩
        var widest = Dotted()
    }

    private(set) var content: Content?

    func set(_ content: Content) {
        if self.content != content { self.content = content }
    }

    /// 收起的页只清自己的：换一份打开时新页的值可能已经先到了。
    func clear(_ page: Workspace.Overlay) {
        if content?.page == page { content = nil }
    }
}

extension View {
    func overlayHeader(_ content: OverlayHeader.Content, in workspace: Workspace) -> some View {
        onChange(of: content, initial: true) { _, content in workspace.overlayHeader.set(content) }
            .onDisappear { workspace.overlayHeader.clear(content.page) }
    }
}

/// 在主区栏头的正中（`MainColumn` 把它叠在那一排上）：下面的正文栏也是居中的。两行都居中：上面是名字，下面一支笔带着改于何时与存没存上（灵感的见 `EditedLine`）。
/// 排成一行过：状态词给最长的那个留着宽，短的时候右边空一截，整块看着偏左。
struct OverlayTitle: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let content = workspace.overlayHeader.content.flatMap { $0.page == workspace.overlay ? $0 : nil }
        VStack(spacing: 0) {
            Text(verbatim: content?.title ?? "").font(Typography.toolbarTitlePaired).foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
            // 按最长的那个状态词留宽（状态换字时玻璃不伸缩），笔跟着字一起居中在里面
            ZStack {
                if let marks = content?.marks {
                    EditedLine(marks: EditedLine.Marks(edited: marks.edited, pinned: marks.pinned, save: .failed)).hidden()
                    EditedLine(marks: marks)
                } else {
                    line(content?.widest ?? Dotted()).hidden()
                    line(content?.detail ?? Dotted())
                }
            }
            .font(Typography.toolbarPath)
            .foregroundStyle(content?.failed == true ? palette.failure : palette.ink3)
        }
        .lineLimit(1)
        .padding(.horizontal, Spacing.part)
        .frame(height: Self.height)
        .glass(in: .capsule)
        .help(content?.help ?? "")
        .accessibilityElement(children: .combine)
        .opacity(content == nil ? 0 : 1)
    }

    private func line(_ text: Dotted) -> some View {
        HStack(spacing: Spacing.tight) {
            Image(.write).accessibilityHidden(true)
            Text(text)
        }
    }

    private static let height: CGFloat = 44
}
#endif
