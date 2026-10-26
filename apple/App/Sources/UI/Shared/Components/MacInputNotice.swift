import CueStore
import SwiftUI

/// 发往 Mac 的输入框上方的说明：没选到 Mac，配置没换成的原因另起一行。会话回复、新会话、发给 Agent 共用。
/// 同步不通不在这里说：说的话照样写下、排着，恢复后自动发出（同对 Cue 说的话）；为什么不通只在同步那一处（`SyncSummary`）。
/// 是否展开、开会话的进度是否优先由调用方决定；文字、字号与颜色只在这里。
struct MacInputNotice: View {
    var noMac = false
    var failure: Speech.Failure?
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if noMac {
                Text(CueStoreError.noMac.localizedDescription).foregroundStyle(palette.ink3)
            }
            if let failure {
                Text("没换成：\(failure.text)").foregroundStyle(palette.failure)
            }
        }
        .font(Typography.caption).lineLimit(2)
    }
}
