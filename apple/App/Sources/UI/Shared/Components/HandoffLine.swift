import CueStore
import SwiftUI

/// 歇着的会话在等哪一处做完（`CueHandoff`，会话卡片第二行、看板卡下沿）：写得下就点名（"等「cuepad」做完"），
/// 写不下换成不点名的那句（"等另一个会话做完"，默认字号下最窄的看板卡也放得下）；字体与颜色随调用处。
struct HandoffLine: View {
    let handoff: CueHandoff

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(handoff.waiting).lineLimit(1).fixedSize()
            Text(handoff.waitingUnnamed).lineLimit(1)
        }
    }
}

extension CueHandoff {
    /// 点名的那句；读屏总念它
    var waiting: String { String(localized: "等「\(name)」做完") }
    var waitingUnnamed: String { task ? String(localized: "等另一件任务做完") : String(localized: "等另一个会话做完") }
}
