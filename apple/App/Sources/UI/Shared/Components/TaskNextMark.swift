import CueStore
import SwiftUI

/// 不垫底、不成胶囊——一屏可能有十几格，胶囊排成一列就成了一墙按钮。
/// 平时次要墨色（手机上一直写着；一个"▶"新用户认不出是开始），指针停在这一行时（`rowHovered`）是靛青（签名色只给焦点，`Palette`）。
/// 状态词只看要不要你管，不随悬停出没：出没会挤动标题与时间，状态标的说明在悬停提示里。
struct TaskNextMark: View {
    let next: TaskNext
    @Environment(\.rowHovered) private var lit
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        #if os(macOS)
        if case .start(let leaf) = next {
            HStack(spacing: 0) {
                mark
                chooser(leaf)
            }
        } else {
            mark
        }
        #else
        mark
        #endif
    }

    private var mark: some View {
        Button(action: follow) { label }
            .buttonStyle(PressStyle())
            .help(next.starts ? help : String(localized: "\(next.speech)，\(help)"))
            .accessibilityLabel(next.speech)
            .accessibilityHint(help)
    }

    #if os(macOS)
    /// "开始"是一点就开（用上次选的那家与模型）；要换的点这个箭头，出来的是新会话的输入框、带着这条任务。
    private func chooser(_ leaf: Card) -> some View {
        Button { workspace.chooseStart(leaf) } label: {
            Image(.expand).font(Self.glyph)
                .foregroundStyle(lit ? palette.signature : palette.ink2)
                .frame(width: Self.target, height: Self.target).contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .help("换 Agent 或模型再开始")
        .accessibilityLabel("选 Agent 与模型再开始")
    }
    #endif

    private var label: some View {
        HStack(spacing: Spacing.glyph) {
            switch next {
            case .agent(let shown, let session):
                StateDot(shown: shown, size: Self.dot).relaySpot(session: session.sessionID, row: .task)
                if shown.speaksOnTask { Text(shown.label).foregroundStyle(shown.labelTint(palette)) }
            case .start:
                Image(.start).font(Self.glyph)
                Text("开始").fontWeight(.semibold)
            }
        }
        .font(TaskMetrics.caption)
        .foregroundStyle(next.starts && lit ? palette.signature : palette.ink2)
        .lineLimit(1).fixedSize()
        // 点按区比图形宽；图形贴着行的那一边（手机行尾的一列右缘对齐，紧跟标题时靠左），不在点按区里居中
        .frame(minWidth: Self.target, minHeight: Self.target, alignment: edge)
        .contentShape(.rect)
        .animation(Motion.fade, value: lit)
    }

    #if os(macOS)
    private var edge: Alignment { .leading }
    private static let dot: CGFloat = 6
    private static let glyph = Glyph.mark
    private static let target: CGFloat = 20
    #else
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    private var edge: Alignment { sizeClass == .regular || typeSize.isAccessibilitySize ? .leading : .trailing }
    private static let dot: CGFloat = 7
    private static let glyph = Typography.caption2.weight(.bold)
    private static let target: CGFloat = TaskMetrics.chipTarget
    #endif

    private var help: String {
        switch next {
        case .agent: String(localized: "打开这件事的 Agent 会话")
        case .start: startHelp
        }
    }

    private var startHelp: String {
        #if os(macOS)
        if case .start(let leaf) = next, let choice = workspace.localAgents.flatMap({ workspace.services.settings.launchChoice(on: $0, in: leaf.projectID) }),
           let agent = choice.agent {
            let brain = [agent.name, choice.current?.displayName].compactMap(\.self).joined(separator: " ")
            return String(localized: "把任务的正文交给 Agent，开始做。开新会话时用 \(brain)，点旁边的箭头可以换")
        }
        #endif
        return String(localized: "把任务的正文交给 Agent，开始做")
    }

    private func follow() { workspace.follow(next) }
}
