#if os(macOS)
import CueStore
import SwiftUI

/// 提示词编辑页底栏右边的"去处 + 交给 Agent"：去处写明白交给哪里（`SendState.destination`：会话是状态点加会话名，新会话写"新会话"加文件夹或项目名），
/// 点去处是换去处的菜单（只对这条提示词所在的任务生效）；靛青主钮"交给 Agent"（⌘↩）按去处交出去（`Workspace.handOff`）。
/// 没有默认去处（没归入项目、也没交给过会话）时只有主钮，点开就是选去处的菜单。会话已结束时去处写"已结束"，交出时在后台唤醒它。
struct SendControl: View {
    let prompt: Card
    /// 提示词所在的任务。
    let task: Card?
    /// 要交出去的正文（选中了就只是选中的部分）。
    let outgoing: () -> String
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        if let destination = workspace.sendState.destination(of: prompt, task: task) {
            HStack(spacing: 10) {
                DestinationMenu(prompt: prompt, current: destination) { chip(destination) }
                    .glass(in: .capsule, interactive: true)
                Button { workspace.handOff(prompt, text: outgoing()) } label: { handLabel(shortcut: true) }
                    .buttonStyle(PressStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(help(destination))
            }
        } else {
            DestinationMenu(prompt: prompt, current: nil) { handLabel(shortcut: false) }
        }
    }

    private func handLabel(shortcut: Bool) -> some View {
        HStack(spacing: 8) {
            Text("交给 Agent")
            if shortcut { Text("⌘↩").opacity(0.6) }
        }
        .primaryCapsule(palette)
    }

    private func chip(_ destination: HandOffDestination) -> some View {
        let state = workspace.sendState
        return HStack(spacing: 7) {
            switch destination {
            case .session(let id):
                let target = AgentTarget(session: id)
                PiStateDot(shown: state.shown(target), size: 6)
                Text(Self.truncated(state.sessionName(id))).lineLimit(1)
                if state.isEnded(target) { Text("已结束").foregroundStyle(palette.ink3) }
            case .newSession:
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).accessibilityHidden(true)
                Text(Dotted("新会话", newSessionPlace)).lineLimit(1)
            }
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(palette.ink3).accessibilityHidden(true)
        }
        .font(Typography.secondary.weight(.medium))
        .foregroundStyle(palette.ink)
        .padding(.horizontal, 14).frame(height: 44)
        .contentShape(.capsule)
    }

    /// 新会话开在哪：项目绑定的文件夹名，还没绑就写项目名（交出时会先让选文件夹）。
    private var newSessionPlace: String? {
        guard let project = prompt.projectID else { return nil }
        let folder = workspace.catalog?.directories[project].map { URL(filePath: $0).lastPathComponent }
        return Self.truncated(folder ?? workspace.catalog?.project(project)?.name ?? "")
    }

    private func help(_ destination: HandOffDestination) -> String {
        switch destination {
        case .session(let id): workspace.sendState.action(for: AgentTarget(session: id))
        case .newSession: "在 \(newSessionPlace ?? "项目")里开新会话并交给它"
        }
    }

    private static func truncated(_ name: String, limit: Int = 14) -> String {
        name.count > limit ? name.prefix(limit - 1) + "…" : name
    }
}

extension View {
    /// 底栏与浮层里的靛青主钮外观（签名色只给主钮）。
    func primaryCapsule(_ palette: Palette) -> some View {
        font(Typography.secondary.weight(.semibold))
            .foregroundStyle(palette.onSignature)
            .padding(.horizontal, 16).frame(height: 44)
            .background(palette.signatureFill, in: .capsule)
            .contentShape(.capsule)
    }
}

/// 选去处的菜单：新会话（项目里的提示词才有）、本项目的在线会话、其他在线会话、本窗口刚结束的会话（可在后台唤醒）；当前的打勾。
/// 选择只记在这条提示词所在的任务上，不发送。在线会话与手机共用同一份列表规则（`HandOffTargets`）。
struct DestinationMenu<Trigger: View>: View {
    let prompt: Card
    let current: HandOffDestination?
    @ViewBuilder let label: () -> Trigger
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let state = workspace.sendState
        let online = state.onlineTargets(for: prompt.projectID)
        let here = online.filter { $0.state.projectID == prompt.projectID && prompt.projectID != nil }
        let elsewhere = online.filter { item in !here.contains { $0.id == item.id } }
        let groups = [here, elsewhere].filter { !$0.isEmpty }
        Menu {
            if prompt.projectID != nil { choice(.newSession) { Label("新会话", systemImage: "plus") } }
            ForEach(groups.indices, id: \.self) { index in
                if index > 0 || prompt.projectID != nil { Divider() }
                ForEach(groups[index]) { item in
                    let id = item.state.sessionID
                    choice(.session(id)) {
                        Text(HandOffTargets.title(item, project: workspace.catalog?.project(item.state.projectID), shown: state.shown(AgentTarget(session: id))))
                    }
                }
            }
            if !state.endedTargets.isEmpty {
                Divider()
                ForEach(state.endedTargets, id: \.sessionID) { ended in
                    choice(.session(ended.sessionID)) { Text(Dotted(ended.title, "已结束")) }
                }
            }
            if prompt.projectID == nil, online.isEmpty, state.endedTargets.isEmpty {
                Button {} label: { Text(Dotted("没有运行中的 Agent 会话", "在终端运行 pi 开始")) }.disabled(true)
            }
        } label: {
            label()
        }
        .menuStyle(.button).buttonStyle(PressStyle(scale: 0.97)).menuIndicator(.hidden).fixedSize()
        .help("选择交给哪个 Agent 会话")
        .accessibilityLabel("选择 Agent 会话")
    }

    private func choice<Content: View>(_ destination: HandOffDestination, @ViewBuilder _ content: () -> Content) -> some View {
        Toggle(isOn: Binding(get: { current == destination }, set: { _ in workspace.sendState.pick(destination, for: prompt) })) { content() }
    }
}
#endif
