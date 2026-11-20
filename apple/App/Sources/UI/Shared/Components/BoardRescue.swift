import CueStore
import SwiftUI

/// 卡住的会话就地处理的那一颗（`SessionRescue`），在卡脚右端，同待办卡的"开始"一个位置、一样高（`TaskNextMark`）。
/// 写着字、垫淡底：原因卡上一直写着（第二行的状态词），这颗说的是能做什么。
/// 否决过：标题右端墨底反白的胶囊——整张卡上它最重，把标题挤短，还顶掉了哪家 Agent 的标志；
/// 只画图标的圆钮——压缩没有一看就懂的图形；反白的实心底是一页一颗的主操作，一列卡里每张卡住的都有一颗就不是了。
struct BoardRescue: View {
    let session: SessionState
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch SessionRescue.of(session) {
            case .usage(let url): Link(destination: url) { face("管理用量") }
            case .retry: Button { workspace.retry(session) } label: { face("重试") }
            case .compact: Button { workspace.compact(session) } label: { face("现在压缩") }
            case nil: EmptyView()
            }
        }
        .buttonStyle(PressStyle(.button))
        .fixedSize()
    }

    private func face(_ title: LocalizedStringKey) -> some View {
        Text(title).font(Typography.label).foregroundStyle(palette.ink)
            .padding(.horizontal, Spacing.group).frame(height: TaskNextMark.disc)
            .background(palette.fill, in: .capsule)
            .frame(minHeight: TaskNextMark.target)
            .contentShape(.rect)
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
