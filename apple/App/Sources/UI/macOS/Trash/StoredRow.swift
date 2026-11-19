#if os(macOS)
import SwiftUI

/// 归档与回收站里的一行，同项目页"更早"的那一行（`OlderRow`）一个样子：直接落在桌面上、不装进纸里，一行定高，
/// 指针停着才在行尾露出操作（只有图形的小钮，同会话条里悬停才露的那种）。行尾只写日期：这一页是归档还是回收站栏头已经说了。时间不让位：标题再长也是标题省略，不把时间挤成一字一行。
struct StoredRow<Mark: View, Actions: View>: View {
    let title: String
    let detail: String
    let stamp: Date?
    @ViewBuilder let mark: Mark
    @ViewBuilder let actions: Actions
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.item) {
            mark.font(Glyph.row).frame(width: Self.markWidth)
            Text(title).font(Typography.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1).layoutPriority(1)
            Text(detail).font(Typography.secondary).lineLimit(1)
            Spacer(minLength: Spacing.group)
            if let stamp { Text(DateLabel.short(stamp)).font(Typography.meta.monospacedDigit()).fixedSize().yieldsToReveal() }
        }
        .foregroundStyle(palette.ink3)
        .frame(height: Self.height)
        .contentShape(.rect)
        .hoverReveal {
            HStack(spacing: Spacing.tight) { actions }
                .labelStyle(.iconOnly).buttonStyle(ControlButtonStyle(kind: .icon, size: .compact))
                .padding(.horizontal, Spacing.tight)
        }
        .row()
    }

    private static var markWidth: CGFloat { 18 }
    private static var height: CGFloat { 38 }
}

extension View {
    /// 归档、回收站那一列行的外框：同项目页的任务区，不宽过阅读栏，靠左。
    func storedList() -> some View {
        frame(maxWidth: Spacing.reading, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, Spacing.page).padding(.bottom, Spacing.section)
    }
}
#endif
