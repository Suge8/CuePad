import CueStore
import SwiftUI

struct BubbleFooter: View {
    let data: BubbleData
    let focus: Card
    let editing: CardEditing?
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents
    @Environment(\.palette) private var palette

    private enum Stage {
        case agent(Card)
        case launching(AgentKind)
        case start(Card, editing: CardEditing?)
    }

    private var stage: Stage? {
        if focus.id == data.goal.id, !data.steps.isEmpty {
            guard case .agent(_, let session)? = workspace.lead(of: data.steps, in: agents) else { return nil }
            return data.steps.first { $0.piSessionID == session.sessionID }.map(Stage.agent)
        }
        if agents.items[focus.id] != nil { return .agent(focus) }
        if let kind = agents.launching[focus.id], !workspace.launchUnsettled(focus.id) { return .launching(kind) }
        return focus.status != .done ? .start(focus, editing: editing) : nil
    }

    var body: some View {
        ZStack(alignment: .leading) {
            switch stage {
            case .agent(let leaf)?: AgentStrip(leaf: leaf).transition(.handOff)
            case .launching(let kind)?: LaunchStrip(kind: kind).transition(.handOff)
            case .start(let leaf, let editing)?: StartBar(leaf: leaf, editing: editing).transition(.handOff)
            case nil: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, stage == nil ? 0 : Spacing.tight)
    }
}

/// 开得慢时（Claude Code 冷启动、第一句落进会话，实测 9–17 秒）这里一直有字，不是一片空白。
private struct LaunchStrip: View {
    let kind: AgentKind
    @Environment(\.palette) private var palette

    var body: some View {
        BubbleStrip(mark: kind.mark.image) {
            HStack(spacing: Spacing.glyph) {
                Spinner(.small)
                Text("正在开 \(kind.name) 会话…").font(BubbleMetrics.strong).foregroundStyle(palette.ink).lineLimit(1)
            }
        } trailing: {
            Color.clear.frame(width: 0, height: max(ControlSize.compact.height, ControlSize.target))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AgentStrip: View {
    let leaf: Card
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents
    @Environment(\.palette) private var palette

    var body: some View {
        if let item = agents.items[leaf.id] {
            #if os(macOS)
            let state = workspace.withLiveState(item.state)
            #else
            let state = item.state
            #endif
            let shown = workspace.shown(state, delivery: item.delivery)
            let look = TaskAgentLook(shown, line: SessionProgress.note(of: state, failure: shown.undelivered?.text))
            Button { workspace.openSession(state.id, sessionID: state.sessionID) } label: { strip(look, shown: shown, session: state) }
                .buttonStyle(PressStyle(.wide))
                .accessibilityElement(children: .combine)
                .accessibilityHint("打开会话")
        }
    }

    private func strip(_ look: TaskAgentLook, shown: SessionShown, session: SessionState) -> some View {
        BubbleStrip(mark: session.agent.known?.mark.image ?? Image(.terminal), markLabel: session.agentMark) {
            VStack(alignment: .leading, spacing: Spacing.hair) {
                HStack(spacing: Spacing.glyph) {
                    StateDot(shown: shown, size: BubbleMetrics.dot).relaySpot(session: session.sessionID, row: .task)
                    Text(look.title).font(BubbleMetrics.strong).foregroundStyle(palette.ink).lineLimit(1)
                }
                if let handoff = workspace.handoff(of: session, shown: shown) {
                    HandoffLine(handoff: handoff).font(BubbleMetrics.meta).foregroundStyle(palette.ink2)
                } else if let note = look.note {
                    Text(note).font(BubbleMetrics.meta).foregroundStyle(palette.ink2).lineLimit(2)
                }
            }
        } trailing: {
            Text("去会话")
                .modifier(ControlSurface(kind: shown.needsYou ? .primary : .secondary, size: .compact))
        }
    }
}

private struct BubbleStrip<Content: View, Trailing: View>: View {
    let mark: Image
    var markLabel: String?
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: BubbleMetrics.gap) {
            mark.font(.system(size: BubbleMetrics.brand)).foregroundStyle(palette.ink2)
                .frame(width: BubbleMetrics.markSlot)
                .accessibilityLabel(markLabel ?? "")
            content
            Spacer(minLength: 4)
            trailing.padding(.trailing, Spacing.item)
        }
        .contentShape(.rect)
    }
}

private struct StartBar: View {
    let leaf: Card
    let editing: CardEditing?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    #if os(macOS)
    @Environment(AppServices.self) private var services
    @State private var launch: MacAgents?
    #endif

    var body: some View {
        #if os(macOS)
        let launching = workspace.sessionLaunching(.card(leaf.id))
        let outcome = launching.outcome(at: services.speech)
        let controls = outcome == nil ? launch.flatMap { services.settings.launchChoice(on: $0, in: leaf.projectID) == nil ? nil : $0 } : nil
        #else
        let outcome: (text: String, failed: Bool)? = nil
        let controls: MacAgents? = nil
        #endif
        HStack(spacing: BubbleMetrics.gap) {
            if let outcome {
                Text(verbatim: outcome.text).font(BubbleMetrics.meta).foregroundStyle(outcome.failed ? palette.failure : palette.ink2).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let controls {
                #if os(macOS)
                HandOffChoice(leaf: leaf)
                #endif
                LaunchControls(mac: controls, project: leaf.projectID)
            }
            Spacer(minLength: 0)
            let title: LocalizedStringResource = outcome != nil ? "重试" : "开始"
            Button(action: start) { SendGlyph(outcome != nil ? .retry : .start) }
                .buttonStyle(PressStyle(.button))
                .accessibilityLabel(title).help(Text(title))
                .accessibilityHint("把任务的正文交给 Agent，开始做")
        }
        #if os(macOS)
        .confirmsLaunchAgain(launching)
        .observingLaunchAgents(id: leaf.id, into: $launch, onError: { _ in }) { [id = leaf.id, here = services.hostID] store in
            guard case .launch(_, let host) = try store.handOffPlan(id, host: here).destination else { return nil }
            return host
        }
        #endif
    }

    private func start() {
        let workspace = workspace, editing = editing, leaf = leaf
        Task {
            do {
                workspace.handOff(try await editing?.flushed() ?? leaf)
            } catch {
                workspace.fail(error)
            }
        }
    }
}

#if os(macOS)
private struct HandOffChoice: View {
    let leaf: Card
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        let sessions = services.liveSessions.live.filter { ($0.state.projectID ?? Project.defaultID) == leaf.projectID }
        let bound = sessions.first { $0.state.sessionID == leaf.piSessionID }
        MenuButton(sections: [
            ChoiceMenu.Section(choices: [ChoiceMenu.Choice(title: "新会话", image: .icon(.add), checked: leaf.piSessionID == nil) { unbind() }]),
            ChoiceMenu.Section(title: "本项目开着的会话", choices: sessions.isEmpty
                ? [ChoiceMenu.Choice(title: "本项目没有开着的会话", disabled: true) {}]
                : sessions.map { item in
                    ChoiceMenu.Choice(title: .verbatim(item.state.title), checked: item.state.sessionID == leaf.piSessionID) { bind(item.state.sessionID) }
                }),
        ], accessibilityLabel: "交给谁", value: bound?.state.title ?? String(localized: "新会话")) {
            DestinationChip(title: Text(bound.map { "交给 \($0.state.title)" } ?? "交给 新会话")) { EmptyView() }
        }
        .layoutPriority(1)
    }

    private func bind(_ sessionID: String) {
        let id = leaf.id
        workspace.perform { try await $0.bindSession(sessionID, to: id) }
    }

    private func unbind() {
        guard leaf.piSessionID != nil else { return }
        let id = leaf.id
        workspace.perform { try await $0.unbindSession(from: id) }
    }
}
#endif
