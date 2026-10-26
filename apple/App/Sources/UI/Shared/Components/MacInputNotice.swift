import CueStore
import SwiftUI

/// 发往 Mac 的输入框上方的说明：没选到 Mac 优先于同步不通，配置没换成的原因另起一行。会话回复、新会话、发给 Agent 共用。
/// 是否展开、开会话的进度是否优先由调用方决定；文字、字号与颜色只在这里。
struct MacInputNotice: View {
    var noMac = false
    var failure: Speech.Failure?
    var consequence: LocalizedStringResource = "发不到 Mac"
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if noMac {
                Text(CueStoreError.noMac.localizedDescription).foregroundStyle(palette.ink3)
            } else if !services.reachesPiHost {
                let summary = SyncSummary(services.syncStatus)
                Label { Text("\(summary.title)：\(Text(consequence))") } icon: { Image(summary.icon) }
                    .font(Typography.meta).foregroundStyle(palette.ink3)
            }
            if let failure {
                Text("没换成：\(failure.text(sync: services.syncStatus))").foregroundStyle(palette.failure)
            }
        }
        .font(Typography.caption).lineLimit(2)
    }
}
