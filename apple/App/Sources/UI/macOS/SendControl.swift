#if os(macOS)
import SwiftUI

/// 提示词的发送钮（⌘↩）+ 选会话：发给本项目的 Agent 会话（`SendState.agentTarget`），有目标时是靛青主钮；
/// 本项目还没有会话时只是选会话的菜单（中性样式）。只在有内容可发时出现（由调用方决定）。
/// 按钮上写"发给 Agent · <会话名>"，过长只截会话名；目标会话已结束时状态点写"已结束"，发送时在后台唤醒它；
/// 会话正忙时转为询问马上说还是等它做完再说（`Workspace.send`）。
struct SendControl: View {
    let project: UUID?
    var compact = false
    /// 给了时菜单最上面多一项"新会话"（见 `Workspace.newSessionHandOff`）。
    var newSession: (() -> Void)? = nil
    let send: (AgentTarget) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let target = workspace.sendState.agentTarget(for: project)
        Group {
            if let target {
                HStack(spacing: 0) {
                    Button { send(target) } label: {
                        label(dot: workspace.sendState.shown(target), text: Dotted("发给 Agent", name(target)), shortcut: "⌘↩")
                            .padding(.trailing, 8)
                    }
                    .buttonStyle(PressStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(workspace.sendState.action(for: target))
                    .help(workspace.sendState.isEnded(target) ? "这个会话已结束，发送时会在后台唤醒它" : "")
                    SessionMenu(project: project, newSession: newSession) {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            .padding(.trailing, compact ? 10 : 14).padding(.leading, 4)
                            .frame(height: compact ? 28 : 44)
                            .contentShape(.rect)
                    }
                }
            } else {
                SessionMenu(project: project, newSession: newSession) {
                    label(dot: nil, text: "交给 Agent…", shortcut: nil)
                        .padding(.trailing, compact ? 12 : 16)
                }
            }
        }
        .font((compact ? Typography.meta : Typography.secondary).weight(.semibold))
        .foregroundStyle(target != nil ? palette.onSignature : palette.ink)
        .background(target != nil ? palette.signatureFill : palette.fill, in: .capsule)
        .shadow(color: .black.opacity(palette.dark || compact ? 0 : 0.12), radius: 6, y: 2)
        .fixedSize()
    }

    private func label(dot: PiShown?, text: Dotted, shortcut: String?) -> some View {
        HStack(spacing: 8) {
            if let dot { PiStateDot(shown: dot, size: 5) } else { Image(systemName: "paperplane.fill").accessibilityHidden(true) }
            Text(text).lineLimit(1)
            if let shortcut { Text(shortcut).opacity(0.6) }
        }
        .padding(.leading, compact ? 12 : 16)
        .frame(height: compact ? 28 : 44)
        .contentShape(.rect)
    }

    /// 截断后的会话名。
    private func name(_ target: AgentTarget) -> String {
        let full = workspace.sendState.sessionName(target.session), limit = compact ? 8 : 14
        return full.count > limit ? full.prefix(limit - 1) + "…" : full
    }
}

/// 选会话的菜单：所有 Mac 上在线的 Agent 会话（手机共用同一份规则，`HandOffTargets`）与本机刚结束的会话（当前的打勾，与发送钮的目标是同一批），
/// 可选"新会话"；都没有时留一行怎么开始。
struct SessionMenu<Label: View>: View {
    let project: UUID?
    var newSession: (() -> Void)? = nil
    @ViewBuilder let label: () -> Label
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        let current = workspace.sendState.agentTarget(for: project)
        Menu {
            if let newSession { Button("新会话", systemImage: "plus", action: newSession) }
            let online = workspace.sendState.onlineTargets(for: project)
            if online.isEmpty, workspace.sendState.endedTargets.isEmpty, newSession == nil {
                Button {} label: { Text(Dotted("没有运行中的 Agent 会话", "在终端运行 pi 开始")) }.disabled(true)
            }
            ForEach(online) { item in
                let id = item.state.sessionID
                Toggle(isOn: Binding(get: { current?.session == id }, set: { _ in workspace.sendState.choice = AgentTarget(session: id) })) {
                    Text(HandOffTargets.title(item, project: workspace.catalog?.project(item.state.projectID), shown: workspace.sendState.shown(AgentTarget(session: id))))
                }
            }
            ForEach(workspace.sendState.endedTargets, id: \.sessionID) { ended in
                Toggle(
                    isOn: Binding(get: { current?.session == ended.sessionID }, set: { _ in workspace.sendState.choice = AgentTarget(session: ended.sessionID) })
                ) { Text(Dotted(ended.title, "已结束")) }
            }
        } label: {
            label()
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("选择 Agent 会话")
        .accessibilityLabel("选择 Agent 会话")
    }
}
#endif
