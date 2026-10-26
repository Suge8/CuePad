import CueStore
import SwiftUI

/// 任务行上"下一步"那一格（`TaskNext`），Mac 与手机同一份，不垫底、不成胶囊——一屏可能有十几格，胶囊排成一列就成了一墙按钮：
/// 会话那边的事是会话状态标（`PiStateDot`，在做时那条心电线自己会动），要你管的（`PiShown.speaksOnTask`）旁边写状态词，点了打开会话；
/// 还没交出去的叶子是带字、不带底的"▶ 开始"，点了把任务的正文交给 Agent（Mac 直接交出，手机浮起发给 Agent 的输入框带着它）；
/// 平时次要墨色（手机上一直写着；一个"▶"新用户认不出是开始），指针停在这一行时（`rowHovered`）是靛青（签名色只给焦点，ui.md）。
/// Mac 上它只在那时浮在行尾（`TaskLine.inlines`），两端同一个样子。
/// 状态词只看要不要你管，不随悬停出没：出没会挤动标题与时间，状态标的说明在悬停提示里。
struct TaskNextMark: View {
    let next: TaskNext
    @Environment(\.rowHovered) private var lit
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: follow) { label }
            .buttonStyle(PressStyle())
            .help(next.starts ? help : String(localized: "\(next.speech)，\(help)"))
            .accessibilityLabel(next.speech)
            .accessibilityHint(help)
    }

    private var label: some View {
        HStack(spacing: 5) {
            switch next {
            case .agent(let shown, let session):
                PiStateDot(shown: shown, size: Self.dot).relaySpot(session: session.sessionID, row: .task)
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
        .animation(HandOff.quick, value: lit)
    }

    #if os(macOS)
    private var edge: Alignment { .leading }
    private static let dot: CGFloat = 6
    private static let glyph = Font.system(size: 8, weight: .bold)
    private static let target: CGFloat = 20
    #else
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    /// 跟着 `TaskLine` 的排法：手机行尾一列时贴右，紧跟标题或换到标题下面时贴左。
    private var edge: Alignment { sizeClass == .regular || typeSize.isAccessibilitySize ? .leading : .trailing }
    private static let dot: CGFloat = 7
    /// 跟着动态字体走：辅助字号下与旁边的字一起放大。
    private static let glyph = Font.caption2.weight(.bold)
    private static let target: CGFloat = TaskMetrics.chipTarget
    #endif

    private var help: String {
        switch next {
        case .agent: String(localized: "打开这件事的 Agent 会话")
        case .start: String(localized: "把任务的正文交给 Agent，开始做")
        }
    }

    private func follow() { workspace.follow(next) }
}
