import SwiftUI

enum Pending {
    static let delay = Duration.milliseconds(400)
}

/// 转圈挂在字前面、不进排版：整块的基线就是字的基线，与同一行按基线对齐的标题对得上（放进 HStack 时基线取转圈的下沿，Mac 会话顶栏的标题会被顶上去半行）。
struct SyncingLabel: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Text("正在同步")
            .padding(.leading, Spinner.Size.mini.side + Self.gap)
            .overlay(alignment: .leading) { Spinner(.mini).readerHidden(true) }
            .foregroundStyle(palette.ink3)
            .accessibilityElement(children: .combine)
    }

    private static let gap = Spacing.tight
}
