import CueStore
import SwiftUI

/// 歇着的会话在等哪一处做完（`CueHandoff`，会话卡片第二行、看板卡下沿）：行首是 Cue 交出去那个动作的图标（与 Cue 页经过里同一个，`CueTrace.icon`），
/// 写得下就点名（"等 cuepad 做完"，名字墨深一档，同经过里名字与动词分两种墨），写不下换成不点名的那句（"等另一个会话做完"，
/// 默认字号下最窄的看板卡也放得下）；字体与其余的颜色随调用处。
struct HandoffLine: View {
    let handoff: CueHandoff
    @Environment(\.palette) private var palette

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(Text("等 \(Text(handoff.name).foregroundStyle(palette.ink)) 做完")).fixedSize()
            line(Text(handoff.waitingUnnamed))
        }
    }

    private func line(_ text: Text) -> some View {
        HStack(spacing: 4) {
            Image(CueTrace.icon(handoff.kind)).accessibilityHidden(true)
            text.lineLimit(1)
        }
    }
}

extension CueHandoff {
    /// 点名的那句（读屏念它）
    var waiting: String { String(localized: "等 \(name) 做完") }
    var waitingUnnamed: String { task ? String(localized: "等另一件任务做完") : String(localized: "等另一个会话做完") }
}
