#if os(macOS)
import CueStore
import SwiftUI

/// 接入面板的第二步（各家都接好了、技能与规则还有一键整理能做的才出现，`SetupPanel`）：同技能与规则页那块纸，
/// 不用你选的那几件逐条写结果的事实（`TidyFacts`），面板底下一颗"一键整理"做完；同名、内容不同的规则不在这里，在技能与规则的文件页里做。
/// 各家自管的技能一句"不动"。
struct SetupLibraryStep: View {
    let library: AgentLibrary
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TidyFacts(tidies: library.automaticTidies, library: library)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(palette.paper, in: .rect(cornerRadius: 10, style: .continuous))
            if !library.selfManaged.isEmpty {
                Text(verbatim: untouched).font(Typography.meta).foregroundStyle(palette.ink3).padding(.horizontal, 4)
            }
        }
    }

    private var untouched: String {
        let parts = library.selfManaged.map(\.title)
        return String(localized: "不动：\(parts.formatted(.list(type: .and)))，由它们自己管")
    }
}
#endif
