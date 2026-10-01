#if os(macOS)
import CueDispatch
import SwiftUI

/// 实心发送按钮（⌘↩）+ 目标选择，底色是强调色（墨）。只在有内容可发时出现（由调用方决定）。
/// 目标默认是本项目的 Pi 会话，没有则是上一个前台应用；选过的目标在本窗口内记住。还没有任何可发的目标时，
/// 按钮写"发送…"，点开就是目标菜单。
struct SendControl: View {
    let project: UUID?
    var compact = false
    let send: (SendChoice) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let choice = workspace.effectiveChoice(for: project)
        Group {
            if choice == .lastApp, services.lastFrontmostApp() == nil {
                SendTargetMenu(project: project) {
                    label(icon: AnyView(Image(systemName: "paperplane.fill").accessibilityHidden(true)), text: "发送…", shortcut: nil)
                        .padding(.trailing, compact ? 12 : 16)
                }
            } else {
                HStack(spacing: 0) {
                    Button { send(choice) } label: {
                        label(icon: AnyView(icon(choice)), text: "发给 \(Self.short(workspace.label(for: choice), compact ? 8 : 14))", shortcut: "⌘↩")
                            .padding(.trailing, 8)
                    }
                    .buttonStyle(PressStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    SendTargetMenu(project: project) {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).accessibilityHidden(true)
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

    /// 目标名过长（应用全名）时截断，按钮宽度随内容但有上限。
    private static func short(_ name: String, _ limit: Int) -> String {
        name.count > limit ? name.prefix(limit - 1) + "…" : name
    }

    @ViewBuilder private func icon(_ choice: SendChoice) -> some View {
        switch choice {
        case .pi(let id), .piInput(let id): PiDot(state: workspace.session(id)?.state, size: 6)
        case .clipboard: Image(systemName: "doc.on.clipboard").accessibilityHidden(true)
        case .app, .lastApp: Image(systemName: "paperplane.fill").accessibilityHidden(true)
        }
    }
}

/// 发送目标菜单：Pi 会话（直接发送 / 放进输入框）、应用（上一个前台应用与正在运行的应用）、剪贴板。
struct SendTargetMenu<Label: View>: View {
    let project: UUID?
    @ViewBuilder let label: () -> Label
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        Menu {
            let sessions = services.pi.sessions
            if !sessions.isEmpty {
                Section("Pi") {
                    ForEach(sessions) { session in
                        let name = Workspace.sessionName(session)
                        Button("\(name) · \(session.state.label)") { choose(.pi(session.id)) }
                        Button("放进 \(name) 的输入框（仅文字）") { choose(.piInput(session.id)) }
                    }
                }
            }
            Section("应用") {
                Button("上一个前台应用") { choose(.lastApp) }
                ForEach(services.runningApps().filter { $0.bundleID != nil }, id: \.pid) { app in
                    Button(app.name) { choose(.app(bundleID: app.bundleID!, name: app.name)) }
                }
            }
            Button("只复制到剪贴板") { choose(.clipboard) }
            Divider()
            Toggle("投送到应用后按回车", isOn: Binding(get: { services.settings.autoSubmit }, set: { services.settings.autoSubmit = $0 }))
        } label: {
            label()
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("选择发送目标")
        .accessibilityLabel("选择发送目标")
    }

    private func choose(_ choice: SendChoice) {
        workspace.sendChoice = choice
    }
}
#endif
