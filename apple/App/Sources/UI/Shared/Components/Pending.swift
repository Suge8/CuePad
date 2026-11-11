import SwiftUI

/// 回到前台的那一拉多在一秒以内：这期间什么都不出，免得一闪；过了 `delay` 还没好才淡入，好了就撤下。
enum Pending {
    /// 比这快的拉取不出指示：一闪而过的转圈比稍等一下更扰人。
    static let delay = Duration.milliseconds(400)
}

extension View {
    func pending(_ active: Bool, shown: Binding<Bool>) -> some View {
        task(id: active) {
            if active { try? await Task.sleep(for: Pending.delay) }
            guard !Task.isCancelled, shown.wrappedValue != active else { return }
            withAnimation(Motion.fade) { shown.wrappedValue = active }
        }
    }
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
