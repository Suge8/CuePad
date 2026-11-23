import SwiftUI

/// 手机上灵感页头名字下面那一行：改于哪天，置顶的前面带一颗图钉。两头各占一格：有没有图钉，日期都在正中。
struct EditedLine: View {
    let edited: Date
    var pinned = false

    var body: some View {
        HStack(spacing: Spacing.tight) {
            slot { if pinned { Image(.pin).font(Self.glyph).iconLabel("已置顶") } }
            Text(DateLabel.short(edited)).monospacedDigit()
                .accessibilityLabel("改于 \(DateLabel.short(edited))")
            slot { EmptyView() }
        }
        .lineLimit(1)
        .imageScale(.small)
    }

    private func slot(@ViewBuilder _ mark: () -> some View) -> some View {
        Color.clear.frame(width: Self.slot, height: Self.slot).overlay { mark().transition(.opacity) }
    }

    private static let slot: CGFloat = 12
    /// 图形比旁边的时间略矮：小号（`imageScale(.small)`）在手机的小字上缩得过头，垫大一档字号补回来。
    private static let glyph = Typography.secondary
}
