#if os(macOS)
import SwiftUI

/// 任务图标接数，不写"任务"二字：图标已经说了。
struct CompactFocus: View {
    let data: ProjectPageData
    let scrollToTop: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: scrollToTop) {
            HStack(spacing: Spacing.item) {
                Image(.above).accessibilityHidden(true)
                if data.taskCounts.open > 0 {
                    Label { Text(data.taskCounts.open, format: .number).monospacedDigit() } icon: { Image(.task) }
                        .foregroundStyle(palette.ink2)
                }
            }
        }
        .buttonStyle(ControlButtonStyle(kind: .glass))
        .help("回到顶部")
        .accessibilityLabel("回到顶部")
        .accessibilityValue(data.taskCounts.open > 0 ? Text("\(data.taskCounts.open) 个任务没做完") : Text(verbatim: ""))
    }
}
#endif
