#if os(macOS)
import CueDispatch
import SwiftUI

/// 实心发送按钮（⌘↩）+ 目标选择。主操作用实心墨色而非玻璃：玻璃着色太浅，白字对比度不够。
/// 目标默认是本项目的 Pi 会话，没有则是上一个前台应用；选过的目标在本窗口内记住。
struct SendControl: View {
    let project: UUID?
    var compact = false
    var disabled = false
    let send: (SendChoice) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let choice = workspace.effectiveChoice(for: project)
        HStack(spacing: 0) {
            Button { send(choice) } label: {
                HStack(spacing: 8) {
                    icon(choice)
                    Text("发给 \(Self.short(workspace.label(for: choice), compact ? 8 : 14))").lineLimit(1)
                    Text("⌘↩").opacity(0.6)
                }
                .padding(.leading, compact ? 12 : 16).padding(.trailing, 8)
                .frame(height: compact ? 28 : 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(disabled)
            SendTargetMenu(project: project) {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    .padding(.trailing, compact ? 10 : 14).padding(.leading, 4)
                    .frame(height: compact ? 28 : 44)
                    .contentShape(.rect)
            }
        }
        .font(.system(size: compact ? 12.5 : 13, weight: .semibold))
        .foregroundStyle(palette.onSolid.opacity(disabled ? 0.6 : 1))
        .background(palette.solid.opacity(disabled ? 0.35 : 1), in: .capsule)
        .shadow(color: .black.opacity(palette.dark ? 0 : 0.12), radius: 6, y: 2)
        .fixedSize()
    }

    /// 目标名过长（应用全名）时截断，按钮宽度随内容但有上限。
    private static func short(_ name: String, _ limit: Int) -> String {
        name.count > limit ? name.prefix(limit - 1) + "…" : name
    }

    @ViewBuilder private func icon(_ choice: SendChoice) -> some View {
        switch choice {
        case .pi(let id), .piInput(let id): PiDot(state: workspace.session(id)?.state, size: 6)
        case .clipboard: Image(systemName: "doc.on.clipboard")
        case .app, .lastApp: Image(systemName: "paperplane.fill")
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
    }

    private func choose(_ choice: SendChoice) {
        workspace.sendChoice = choice
    }
}
#endif
