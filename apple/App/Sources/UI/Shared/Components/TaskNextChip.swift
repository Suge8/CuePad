import CueStore
import SwiftUI

/// 任务行上"下一步"那一格（`TaskNext`）画成一颗胶囊，Mac 与手机同一份（Mac 紧跟标题，手机在行尾：屏窄，行尾就在眼前）：会话那边的事写状态标、状态词（要你看的用状态色，Mac 上在做时加计时），
/// 点了打开会话；写好了草稿的是"▶ 开始"，点了把草稿交给 Agent（Mac 直接交出，手机浮起发给 Agent 的输入框带着它）。
/// 胶囊是墨色淡底：一屏可能有好几颗"开始"，靛青只给指针停着的那一行（`lit`）或那一颗（ui.md：签名色只落在焦点上）。
struct TaskNextChip: View {
    let next: TaskNext
    /// 指针停在这一行上（Mac 的任务行）："开始"先亮起来，告诉你这一行能直接开工。
    var lit = false
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif
    @State private var hovering = false

    var body: some View {
        Button(action: go) {
            HStack(spacing: 5) {
                switch next {
                case .agent(let shown, _):
                    PiStateDot(shown: shown, size: 6)
                    Text(shown.label).foregroundStyle(shown.needsYou ? shown.labelTint(palette) : palette.ink2)
                    #if os(macOS)
                    // 在做时写跑了多久；手机上行窄，省掉，标题不被挤成两行
                    if next.agentBusy, !shown.needsYou { PiElapsed(shown: shown, font: TaskMetrics.caption) }
                    #endif
                    Image(systemName: "chevron.right").font(.system(size: Self.glyph, weight: .semibold)).foregroundStyle(palette.ink3)
                case .start:
                    Image(systemName: "play.fill").font(.system(size: Self.glyph, weight: .bold))
                    Text("开始").fontWeight(.semibold)
                }
            }
            .font(Self.font)
            .foregroundStyle(starts && (lit || hovering) ? palette.onSignature : palette.ink)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, Self.inset).frame(height: Self.height)
            .background(starts && (lit || hovering) ? palette.signatureFill : palette.fill, in: .capsule)
            .animation(Motion.quick, value: lit || hovering)
            .contentShape(.capsule.inset(by: -Self.reach))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(next.speech)
        .accessibilityHint(help)
    }

    private var starts: Bool { if case .start = next { true } else { false } }

    #if os(macOS)
    private static let height: CGFloat = 24
    private static let inset: CGFloat = 10
    private static let glyph: CGFloat = 9
    /// 比行里的元信息大一档：它是这一行唯一能直接动手的东西。
    private static let font = Typography.secondary
    /// 点得到的范围比胶囊四周多出这么多（不撑高行）。
    private static let reach: CGFloat = 5
    #else
    private static let height: CGFloat = 28
    private static let inset: CGFloat = 11
    private static let glyph: CGFloat = 9
    private static let font = TaskMetrics.caption
    private static let reach = (TaskMetrics.chipTarget - height) / 2
    #endif

    private var help: String {
        switch next {
        case .agent: "打开这件事的 Agent 会话"
        case .start: "把写好的话交给 Agent，开始做"
        }
    }

    private func go() {
        switch next {
        case .agent(_, let session):
            #if os(macOS)
            workspace.show(.session(session.sessionID))
            #else
            navigation.openSession(session.id, sessionID: session.sessionID, store: services.store)
            #endif
        case .start(let draft):
            #if os(macOS)
            workspace.handOff(draft)
            #else
            navigation.handToAgent(draft)
            #endif
        }
    }
}
