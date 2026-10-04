#if os(macOS)
import CueDispatch
import SwiftUI

/// 实心发送按钮（⌘↩）+ 目标选择，底色是强调色（墨）。只在有内容可发时出现（由调用方决定）。
/// 目标默认是本项目的 Pi 会话，没有则是上一个前台应用；选过的目标在本窗口内记住。按钮上写方式与目标：
/// "发给 Pi · <会话名>"、"放进输入框 · <会话名>"、"发给 <应用>"，过长时只截会话名或应用名，方式不截。
/// 还没有可发的目标时写"发送…"；选过的 Pi 会话已结束时写"<会话名> · 已结束"——这两种点开都是目标菜单。
struct SendControl: View {
    let project: UUID?
    var compact = false
    let send: (AppServices.Destination) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let choice = workspace.effectiveChoice(for: project)
        Group {
            if case .pi(let id, _) = choice, workspace.isEnded(choice) {
                SendTargetMenu(project: project) {
                    label(icon: AnyView(PiStateDot(state: .known(.ended), size: 5)), text: "\(name(of: choice)) · 已结束", shortcut: nil)
                        .padding(.trailing, compact ? 12 : 16)
                }
                .accessibilityLabel("Pi 会话「\(workspace.sessionName(id))」已结束，选择发送目标")
            } else if choice == .app(.lastFrontmost), services.lastFrontmostApp() == nil {
                SendTargetMenu(project: project) {
                    label(icon: AnyView(Image(systemName: "paperplane.fill").accessibilityHidden(true)), text: "发送…", shortcut: nil)
                        .padding(.trailing, compact ? 12 : 16)
                }
            } else {
                HStack(spacing: 0) {
                    Button { send(choice) } label: {
                        label(icon: AnyView(icon(choice)), text: title(choice), shortcut: "⌘↩")
                            .padding(.trailing, 8)
                    }
                    .buttonStyle(PressStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(spoken(choice))
                    SendTargetMenu(project: project) {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            .padding(.trailing, compact ? 10 : 14).padding(.leading, 4)
                            .frame(height: compact ? 28 : 44)
                            .contentShape(.rect)
                    }
                }
            }
        }
        .font(.system(size: compact ? 12.5 : 13, weight: .semibold))
        .foregroundStyle(palette.onAccent)
        .background(palette.accent, in: .capsule)
        .shadow(color: .black.opacity(palette.dark ? 0 : 0.12), radius: 6, y: 2)
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
        case .pi: "发给 Pi · \(name(of: choice))"
        default: "发给 \(name(of: choice))"
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
        case .pi(let id, _): PiStateDot(state: workspace.session(id)?.state.work ?? .known(.ended), size: 5)
        case .clipboard: Image(systemName: "doc.on.clipboard").accessibilityHidden(true)
        case .app: Image(systemName: "paperplane.fill").accessibilityHidden(true)
        }
    }
}

/// 发送目标菜单：Pi 会话（直接发送 / 放进输入框）、应用（上一个前台应用与正在运行的应用）、剪贴板。当前目标打勾。
/// 没有运行中的 Pi 会话时，Pi 区留一行说明怎么开始。
struct SendTargetMenu<Label: View>: View {
    let project: UUID?
    @ViewBuilder let label: () -> Label
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        let current = workspace.effectiveChoice(for: project)
        Menu {
            Section("Pi") {
                let sessions = services.pi.sessions
                if sessions.isEmpty {
                    Button("没有运行中的 Pi 会话 · 在终端运行 pi 开始") {}.disabled(true)
                }
                ForEach(sessions) { session in
                    let name = session.displayName
                    option("\(name) · \(session.state.work.label)", .pi(session.id, .send), current: current)
                    option("放进 \(name) 的输入框（仅文字）", .pi(session.id, .paste), current: current)
                }
            }
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

    /// 一个目标：当前生效的那个打勾。
    private func option(_ title: String, _ choice: AppServices.Destination, current: AppServices.Destination) -> some View {
        Toggle(title, isOn: Binding(get: { current == choice }, set: { _ in workspace.sendChoice = choice }))
    }
}
#endif
