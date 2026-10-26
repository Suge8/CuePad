#if os(macOS)
import CueStore
import SwiftUI

/// 接入面板的第二步（各家都接好了、技能与说明还有要整理的才出现，`SetupPanel`）：把"全部整理"会做的每件事列出来，一个按钮做完。
/// 一件一行，写它会做什么（同技能与说明页的写法）；全局规则各写一份的那件旁边一颗"比一比"，先去看看各份有什么不同。
/// 要你挑的（同名、格式不对）不在这里做，最后一句说去技能与说明里看；各家自管的技能一句"不动"。
struct SetupLibraryStep: View {
    let library: AgentLibrary
    let compare: (String) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let automatic = library.tidies.filter(\.isAutomatic)
        let left = library.tidies.count - automatic.count
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                ForEach(automatic) { tidy in
                    LibraryRow(title: tidy.title, detail: workspace.detail(of: tidy, in: library)) {
                        Image(tidy.icon).foregroundStyle(palette.ink)
                    } trailing: {
                        if tidy.action == .compare {
                            Button("比一比") { compare(tidy.id) }.buttonStyle(ControlButtonStyle(kind: .secondary, compact: true))
                        }
                    }
                    .padding(.horizontal, -4)
                    if tidy.id != automatic.last?.id { Divider().padding(.leading, LibraryRowMetrics.icon + LibraryRowMetrics.gap + 12) }
                }
            }
            .background(palette.paper, in: .rect(cornerRadius: 10, style: .continuous))
            Group {
                if left > 0 { Text("另有 \(left) 件要你挑，在技能与说明里") }
                if !library.selfManaged.isEmpty { Text(verbatim: untouched) }
            }
            .font(Typography.meta).foregroundStyle(palette.ink3).padding(.horizontal, 4)
        }
    }

    private var untouched: String {
        let parts = library.selfManaged.map(\.title)
        return String(localized: "不动：\(parts.formatted(.list(type: .and)))，由它们自己管")
    }
}
#endif
