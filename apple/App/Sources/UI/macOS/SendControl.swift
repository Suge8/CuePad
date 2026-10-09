#if os(macOS)
import CueDispatch
import SwiftUI

/// 发送按钮（⌘↩）+ 目标选择：主次由 `Workspace.sendStyle` 一处定——发给 Agent 能一按就发时是靛青主钮，发给应用或剪贴板是次要样式，
/// 只能选目标时是中性的菜单。只在有内容可发时出现（由调用方决定）。
/// 目标默认是本项目的 Pi 会话，没有则是上一个前台应用；选过的目标在本窗口内记住。发的是灵感（`agents` 为 false）时只有应用与剪贴板：
/// 发给 Agent 只经任务的提示词（`CardMenu.handsToAgent`）。按钮上写方式与目标：
/// "发给 Agent · <会话名>"、"放进输入框 · <会话名>"、"粘贴到 <应用>"、"复制到剪贴板"，过长时只截会话名或应用名，方式不截。
/// 还没有可发的目标时写"发送…"；选过的 Pi 会话已结束时写"<会话名> · 已结束"——这两种点开都是目标菜单。
struct SendControl: View {
    let project: UUID?
    /// 目标里有没有 Agent 会话。
    let agents: Bool
    var compact = false
    /// 绑 ⌘↩：同一处另有主动作占着 ⌘↩（灵感纸页的"挂到任务"）时不绑。
    var bindsReturn = true
    /// 给了时目标菜单的 Agent 区多一项"新会话"（从提示词交给 Agent，见 `Workspace.newSessionHandOff`）。
    var newSession: (() -> Void)? = nil
    let send: (AppServices.Destination) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let choice = workspace.effectiveChoice(for: project, agents: agents), style = workspace.sendStyle(choice)
        Group {
            if style != .menu {
                HStack(spacing: 0) {
                    Button { send(choice) } label: {
                        label(icon: AnyView(icon(choice)), text: title(choice), shortcut: bindsReturn ? "⌘↩" : nil)
                            .padding(.trailing, 8)
                    }
                    .buttonStyle(PressStyle())
                    .keyboardShortcut(bindsReturn ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .accessibilityLabel(spoken(choice))
                    SendTargetMenu(project: project, agents: agents, newSession: newSession) {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            .padding(.trailing, compact ? 10 : 14).padding(.leading, 4)
                            .frame(height: compact ? 28 : 44)
                            .contentShape(.rect)
                    }
                }
            } else if case .pi(let id, _) = choice {
                SendTargetMenu(project: project, agents: agents, newSession: newSession) {
                    label(icon: AnyView(PiStateDot(shown: PiShown(state: .known(.ended)), size: 5)), text: "\(name(of: choice)) · 已结束", shortcut: nil)
                        .padding(.trailing, compact ? 12 : 16)
                }
                .accessibilityLabel("Agent 会话「\(workspace.sessionName(id))」已结束，选择发送目标")
            } else {
                SendTargetMenu(project: project, agents: agents, newSession: newSession) {
                    label(icon: AnyView(Image(systemName: "paperplane.fill").accessibilityHidden(true)), text: "发送…", shortcut: nil)
                        .padding(.trailing, compact ? 12 : 16)
                }
            }
        }
        .font(.system(size: compact ? 12.5 : 13, weight: .semibold))
        // 主钮（靛青）只有发给 Agent 的发送；发给应用与只能选目标时是中性的
        .foregroundStyle(style == .primary ? palette.onSignature : palette.ink)
        .background(style == .primary ? palette.signature : palette.fill, in: .capsule)
        // 浮在页面上时带一点投影；放在稿纸里（compact）是平的
        .shadow(color: .black.opacity(palette.dark || compact ? 0 : 0.12), radius: 6, y: 2)
        .fixedSize()
    }

    private func label(icon: AnyView, text: String, shortcut: String?) -> some View {
        HStack(spacing: 8) {
            icon
            Text(text).lineLimit(1)
            if let shortcut { Text(shortcut).opacity(0.6) }
        }
        .padding(.leading, compact ? 12 : 16)
        .frame(height: compact ? 28 : 44)
        .contentShape(.rect)
    }

    /// 按钮上的字：方式在前、不截；名字过长时截断。
    private func title(_ choice: AppServices.Destination) -> String {
        switch choice {
        case .pi(_, .paste): "放进输入框 · \(name(of: choice))"
        case .pi: "发给 Agent · \(name(of: choice))"
        // 应用名单独写在按钮上常认不出是应用（"粘贴到 预览"），加上 App
        case .app: "粘贴到 \(name(of: choice)) App"
        case .clipboard: "复制到剪贴板"
        }
    }

    /// 读屏念完整的说法（按钮上的名字可能截断）。
    private func spoken(_ choice: AppServices.Destination) -> String {
        workspace.action(for: choice)
    }

    /// 截断后的会话名或应用名。
    private func name(of choice: AppServices.Destination) -> String {
        let full = if case .pi(let id, _) = choice { workspace.sessionName(id) } else { workspace.label(for: choice) }
        let limit = compact ? 8 : 14
        return full.count > limit ? full.prefix(limit - 1) + "…" : full
    }

    @ViewBuilder private func icon(_ choice: AppServices.Destination) -> some View {
        switch choice {
        case .pi(_, .paste): Image(systemName: "text.cursor").accessibilityHidden(true)
        case .pi(let id, _): PiStateDot(shown: workspace.session(id).map(workspace.shown) ?? PiShown(state: .known(.ended)), size: 5)
        case .clipboard: Image(systemName: "doc.on.clipboard").accessibilityHidden(true)
        case .app: Image(systemName: "paperplane.fill").accessibilityHidden(true)
        }
    }
}

/// 发送目标菜单：Pi 会话（直接发送 / 放进输入框；`agents` 为 false 时没有这一区）、应用（上一个前台应用与正在运行的应用）、剪贴板。
/// 当前目标打勾。没有运行中的 Pi 会话时，Pi 区留一行说明怎么开始。
struct SendTargetMenu<Label: View>: View {
    let project: UUID?
    let agents: Bool
    var newSession: (() -> Void)? = nil
    @ViewBuilder let label: () -> Label
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        let current = workspace.effectiveChoice(for: project, agents: agents)
        Menu {
            if agents { agentSection(current) }
            Section("应用") {
                option("上一个前台应用", .app(.lastFrontmost), current: current)
                ForEach(services.runningApps().filter { $0.bundleID != nil }, id: \.pid) { app in
                    option(app.name, .app(.bundleID(app.bundleID!)), current: current)
                }
            }
            option("只复制到剪贴板", .clipboard, current: current)
            Divider()
            Toggle(isOn: Binding(get: { services.settings.autoSubmit }, set: { services.settings.autoSubmit = $0 })) {
                Text("投送到应用后按回车")
                Text(services.settings.autoSubmit ? "已开启" : "已关闭")
            }
        } label: {
            label()
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("选择发送目标")
        .accessibilityLabel("选择发送目标")
    }

    private func agentSection(_ current: AppServices.Destination) -> some View {
        Section("Agent") {
            let sessions = services.pi.sessions
            if let newSession { Button("新会话", systemImage: "plus", action: newSession) }
            if sessions.isEmpty, newSession == nil {
                Button("没有运行中的 Agent 会话 · 在终端运行 pi 开始") {}.disabled(true)
            }
            ForEach(sessions) { session in
                let name = session.displayName
                option("\(name) · \(workspace.shown(session).label)", .pi(session.id, .send), current: current)
                option("放进 \(name) 的输入框（仅文字）", .pi(session.id, .paste), current: current)
            }
        }
    }

    /// 一个目标：当前生效的那个打勾。
    private func option(_ title: String, _ choice: AppServices.Destination, current: AppServices.Destination) -> some View {
        Toggle(title, isOn: Binding(get: { current == choice }, set: { _ in workspace.sendChoice = choice }))
    }
}
#endif
