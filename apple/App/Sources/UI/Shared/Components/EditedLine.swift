import SwiftUI

/// 灵感编辑页栏头标题下面那一行。状态只画图形：置顶是图钉、存着是转圈、存上了是勾，读屏照旧念字；没存上要人处理，写成字。
/// 两侧各留一格见方的位置，图钉在左、存没存上在右，有没有都占着：笔与时间一直在标题正下方，状态来去时不左右挪。
struct EditedLine: View {
    struct Marks: Equatable {
        var edited: Date
        var pinned = false
        var save = SaveState.idle
    }

    let marks: Marks

    var body: some View {
        HStack(spacing: Spacing.tight) {
            slot { if marks.pinned { Image(.pin).iconLabel("已置顶") } }
            if marks.save == .failed, let text = marks.save.text {
                Text(text)
            } else {
                Image(.write).iconLabel("改于")
                Text(DateLabel.short(marks.edited)).monospacedDigit()
            }
            slot {
                switch marks.save {
                case .saving: Spinner(.mini).accessibilityLabel(Text(marks.save.text ?? ""))
                case .saved: Image(.checked).accessibilityLabel(Text(marks.save.text ?? ""))
                case .idle, .failed: EmptyView()
                }
            }
        }
        .lineLimit(1)
        .animation(Motion.fade, value: marks.save)
    }

    private func slot(@ViewBuilder _ mark: () -> some View) -> some View {
        Color.clear.frame(width: Self.slot, height: Self.slot).overlay { mark().transition(.opacity) }
    }

    private static let slot: CGFloat = 12
}
