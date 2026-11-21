import SwiftUI

struct EditedLine: View {
    struct Marks: Equatable {
        var edited: Date
        var pinned = false
        var save = SaveState.idle
    }

    let marks: Marks

    var body: some View {
        HStack(spacing: Spacing.tight) {
            slot { if marks.pinned { Image(.pin).font(Self.glyph).iconLabel("已置顶") } }
            if marks.save == .failed, let text = marks.save.text {
                Text(text)
            } else {
                Text(DateLabel.short(marks.edited)).monospacedDigit()
                    .accessibilityLabel("改于 \(DateLabel.short(marks.edited))")
            }
            slot {
                switch marks.save {
                case .saving: Spinner(.mini).accessibilityLabel(Text(marks.save.text ?? ""))
                case .saved: Image(.checked).font(Self.glyph).accessibilityLabel(Text(marks.save.text ?? ""))
                case .idle, .failed: EmptyView()
                }
            }
        }
        .lineLimit(1)
        .imageScale(.small)
        .animation(Motion.fade, value: marks.save)
    }

    private func slot(@ViewBuilder _ mark: () -> some View) -> some View {
        Color.clear.frame(width: Self.slot, height: Self.slot).overlay { mark().transition(.opacity) }
    }

    private static let slot: CGFloat = 12
    /// 图形比旁边的时间略矮：小号（`imageScale(.small)`）在手机的小字上缩得过头，垫大一档字号补回来。
    #if os(macOS)
    private static let glyph: Font? = nil
    #else
    private static let glyph: Font? = Typography.secondary
    #endif
}
