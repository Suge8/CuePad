import CueStore
import SwiftUI

/// 卡住的会话就地处理的那一颗（`SessionRescue`），在卡脚右端，同待办卡的"开始"一个位置、一样大（`TaskNextMark`）。
/// 原因卡上一直写着（第二行的状态词），这颗只画图标；墨底反白，一列卡里一眼找得到，不用红（红留给原因那几个字）。
/// 否决过：标题右端写着字的胶囊——整张卡上它最重，把标题挤短，还顶掉了哪家 Agent 的标志。
struct BoardRescue: View {
    let session: SessionState
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch SessionRescue.of(session) {
            case .usage(let url): Link(destination: url) { face(.openInBrowser, "管理用量") }
            case .retry: Button { workspace.retry(session) } label: { face(.retry, "重试") }
            case .compact: Button { workspace.compact(session) } label: { face(.compact, "现在压缩") }
            case nil: EmptyView()
            }
        }
        .buttonStyle(PressStyle(.button))
        .fixedSize()
    }

    private func face(_ icon: Icon, _ title: LocalizedStringResource) -> some View {
        Label(title, icon: icon).labelStyle(.iconOnly).font(TaskNextMark.glyph).foregroundStyle(palette.desk)
            .frame(width: TaskNextMark.disc, height: TaskNextMark.disc)
            .background(palette.ink, in: .circle)
            .frame(minWidth: TaskNextMark.target, minHeight: TaskNextMark.target, alignment: .trailing)
            .contentShape(.rect)
            .help(Text(title))
    }
}

extension View {
    /// 浮在卡上、不放进卡里：会话卡整张是一颗按钮（`BoardLink`），钮里不套钮。卡脚里给它留着宽（`BoardCardLayout`），这里对着卡脚居中。
    func boardRescue(_ session: SessionState?) -> some View {
        overlay(alignment: .bottomTrailing) {
            if let session, SessionRescue.of(session) != nil {
                BoardRescue(session: session).padding(.trailing, TaskMetrics.cardPadding)
                    .offset(y: (TaskNextMark.target - BoardCardMetrics.vitals) / 2 - BoardCardMetrics.pad)
            }
        }
    }
}
