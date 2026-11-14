#if os(macOS)
import SwiftUI

/// 栏头在主窗口里常驻，编辑页只把算好的值交到这里，收起时清掉自己的。
@Observable
final class OverlayHeader {
    struct Content: Equatable {
        var page: Workspace.Overlay
        var title: String
        var detail: Dotted
        var failed = false
        var help: String?
        /// 次要一行最宽的样子（换上最长的那个状态词）：玻璃按它留宽，状态换字时不伸缩
        var widest: Dotted
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

struct PageTitleWidth: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(minWidth: 160, idealWidth: 420, maxWidth: 420)
    }
}

struct OverlayTitle: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let content = workspace.overlayHeader.content.flatMap { $0.page == workspace.overlay ? $0 : nil }
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: Spacing.hair) {
                Text(verbatim: content?.title ?? "").font(Typography.toolbarTitlePaired).foregroundStyle(palette.ink)
                    .accessibilityAddTraits(.isHeader)
                ZStack {
                    Text(content?.widest ?? Dotted()).hidden().accessibilityHidden(true)
                    Text(content?.detail ?? Dotted()).foregroundStyle(content?.failed == true ? palette.failure : palette.ink3)
                }
                .font(Typography.toolbarPath)
            }
            .lineLimit(1)
            .padding(.horizontal, Spacing.block)
            .frame(height: ControlMetrics.height)
            .glass(in: .capsule)
            .help(content?.help ?? "")
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
        .modifier(PageTitleWidth())
    }
}
#endif
