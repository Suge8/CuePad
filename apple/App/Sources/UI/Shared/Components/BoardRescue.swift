import CueStore
import SwiftUI

/// 卡住的会话就地处理的那一颗（`SessionRescue`），在卡脚右端，同待办卡的"开始"一个位置、一样大、一样的淡底（`TaskNextMark`）。
/// 压缩与重试只画图标：压缩用的是"正在压缩上下文"那个状态的图形（弹簧），卡上、侧栏里天天见；管理用量没有认得出的图形，写字。
/// 原因卡上一直写着（第二行的状态词、卡脚的百分比）。
/// 否决过：标题右端墨底反白的胶囊——整张卡上它最重，把标题挤短，还顶掉了哪家 Agent 的标志；
/// 反白的实心底是一页一颗的主操作，一列卡里每张卡住的都有一颗就不是了。
struct BoardRescue: View {
    let session: SessionState
    /// 只占排版的那一份（`BoardCardLayout` 在卡脚里留宽）：不带比图形宽出的点按区。
    var reserves = false
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch SessionRescue.of(session) {
            case .usage(let url): Link(destination: url) { face { Text("管理用量").font(Typography.label).padding(.horizontal, Spacing.group) } }
            case .retry: Button { workspace.retry(session) } label: { face { RescueDisc.glyph(.retry, "重试") } }
            case .compact: Button { workspace.compact(session) } label: { face { RescueDisc.glyph(.compacting, "现在压缩") } }
            case nil: EmptyView()
            }
        }
        .buttonStyle(PressStyle(.button))
        .fixedSize()
    }

    private func face(@ViewBuilder _ label: () -> some View) -> some View {
        label().rescueFace(palette)
            .frame(minWidth: reserves ? nil : TaskNextMark.target, minHeight: reserves ? nil : TaskNextMark.target, alignment: .trailing)
            .contentShape(.rect)
    }
}

/// 淡底圆上一颗墨色图标：卡脚的重试与压缩、上下文气泡里的压缩是同一颗。点得到的那一圈比圆大（`TaskNextMark.target`），
/// 让出来的那一截不占排版：圆的边同旁边的字、条对齐。
struct RescueDisc: View {
    let icon: Icon
    let title: LocalizedStringResource
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) { Self.glyph(icon, title).rescueFace(palette).padding(Self.reach).contentShape(.rect) }
            .buttonStyle(PressStyle(.button))
            .padding(-Self.reach)
    }

    static func glyph(_ icon: Icon, _ title: LocalizedStringResource) -> some View {
        Label(title, icon: icon).labelStyle(.iconOnly).font(font).frame(width: TaskNextMark.disc).help(Text(title))
    }

    private static let reach = (TaskNextMark.target - TaskNextMark.disc) / 2
    #if os(macOS)
    private static let font = Glyph.small
    #else
    private static let font = Typography.caption.weight(.semibold)
    #endif
}

private extension View {
    func rescueFace(_ palette: Palette) -> some View {
        foregroundStyle(palette.ink).frame(height: TaskNextMark.disc).background(palette.fill, in: .capsule)
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
