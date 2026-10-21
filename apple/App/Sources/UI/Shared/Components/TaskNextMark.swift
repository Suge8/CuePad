import CueStore
import SwiftUI

/// 任务行上"下一步"那一格（`TaskNext`），Mac 与手机同一份，不垫底、不成胶囊——一屏可能有十几格，胶囊排成一列就成了一墙按钮：
/// 会话那边的事是会话状态标（`PiStateDot`，在做时那条心电线自己会动），要你管的（`PiShown.speaksOnTask`）旁边写状态词，点了打开会话；
/// 还没交出去的叶子是一个"▶"，点了把任务的正文交给 Agent（Mac 直接交出，手机浮起发给 Agent 的输入框带着它）。
/// 指针停在这一行时（`rowHovered`）"▶ 开始"是靛青（签名色只给焦点，ui.md）；Mac 上"开始"只在那时浮在行尾（`TaskLine.inlines`）。
/// 状态词只看要不要你管，不随悬停出没：出没会挤动标题与时间，状态标的说明在悬停提示里。
struct TaskNextMark: View {
    let next: TaskNext
    @Environment(\.rowHovered) private var lit
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        Button(action: follow) { label }
            .buttonStyle(PressStyle())
            .help(next.starts ? help : Dotted(next.speech, help).visible)
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
                #if os(macOS)
                Text("开始").fontWeight(.semibold)
                #endif
            }
        }
        .font(TaskMetrics.caption)
        // 没亮起的"▶"与待办的圈同一个淡墨：它是这一行可以做的事，不是要你看的事
        .foregroundStyle(next.starts ? (lit ? palette.signature : palette.ink3) : palette.ink2)
        .lineLimit(1).fixedSize()
        // 点按区比图形宽；图形贴着行的那一边（手机行尾的一列右缘对齐，紧跟标题时靠左），不在点按区里居中
        .frame(minWidth: Self.target, minHeight: Self.target, alignment: edge)
        .contentShape(.rect)
        .animation(Motion.quick, value: lit)
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
        case .agent: "打开这件事的 Agent 会话"
        case .start: "把任务的正文交给 Agent，开始做"
        }
    }

    private func follow() {
        #if os(macOS)
        workspace.follow(next)
        #else
        navigation.follow(next, store: services.store)
        #endif
    }
}

#if os(macOS)
extension Workspace {
    /// 去"下一步"：打开会话，或把任务的正文交给 Agent。
    func follow(_ next: TaskNext) {
        switch next {
        case .agent(_, let session): show(.session(session.sessionID))
        case .start(let leaf): handOff(leaf)
        }
    }
}
#else
extension Navigation {
    /// 去"下一步"：推入会话页，或浮起发给 Agent 的输入框带着这条任务。
    func follow(_ next: TaskNext, store: CueStore) {
        switch next {
        case .agent(_, let session): openSession(session.id, sessionID: session.sessionID, store: store)
        case .start(let leaf): handToAgent(leaf)
        }
    }
}
#endif
