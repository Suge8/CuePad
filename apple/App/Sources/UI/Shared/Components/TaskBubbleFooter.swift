import CueStore
import SwiftUI

struct BubbleFooter: View {
    let data: BubbleData
    let focus: Card
    let editing: CardEditing?
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents

    /// 开始 → 正在开 → Agent 在做是同一条的三个样子：旧的先淡完、新的再淡入（`handOff`），不叠着换。
    var body: some View {
        if focus.id == data.goal.id, !data.steps.isEmpty {
            switch workspace.lead(of: data.steps, in: agents) {
            case .agent(_, let session)?:
                if let step = data.steps.first(where: { $0.piSessionID == session.sessionID }) { AgentStrip(leaf: step).transition(.handOff) }
            case .start(let leaf)?: StartBar(leaf: leaf, caption: leaf.title, editing: nil).transition(.handOff)
            case nil: EmptyView()
            }
        } else if agents.items[focus.id] != nil {
            AgentStrip(leaf: focus).transition(.handOff)
        } else if let kind = agents.launching[focus.id], !unsettled(focus.id) {
            LaunchStrip(kind: kind).transition(.handOff)
        } else if focus.status != .done {
            StartBar(leaf: focus, caption: nil, editing: editing).transition(.handOff)
        }
    }

    private func unsettled(_ leaf: UUID) -> Bool {
        #if os(macOS)
        switch workspace.sessionLaunching(.card(leaf)).phase(at: workspace.services.speech) {
        case .unconfirmed, .missing: true
        default: false
        }
        #else
        false
        #endif
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
            trailing
        }
        .padding(BubbleMetrics.stripPadding)
        .background(palette.fill, in: Radius.nested)
        .contentShape(.rect)
    }
}

/// Mac 上这一下要开新会话时，左边是用哪家、哪个模型的那一排（同新会话的输入框，改了就记住）；接着用已有会话的不放。
/// 这台 Mac 上上一次没开成或说不出结果（`SessionLaunching.outcome`）时左边换成原因、按钮写"重试"，可能已开过时先确认。
private struct StartBar: View {
    let leaf: Card
    let caption: String?
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
        VStack(alignment: .leading, spacing: Spacing.item) {
            if let caption, outcome != nil || controls != nil { captioned(caption) }
            HStack(spacing: BubbleMetrics.gap) {
                if let outcome {
                    Text(verbatim: outcome.text).font(BubbleMetrics.meta).foregroundStyle(outcome.failed ? palette.failure : palette.ink2).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let controls {
                    LaunchControls(mac: controls, project: leaf.projectID)
                } else if let caption {
                    captioned(caption)
                }
                Spacer(minLength: 0)
                Button(action: start) {
                    Label(outcome != nil ? "重试" : caption == nil ? "开始" : "开始这一步", icon: .start)
                }
                .buttonStyle(ControlButtonStyle(kind: .primary, size: .compact))
                .accessibilityHint("把任务的正文交给 Agent，开始做")
            }
        }
        #if os(macOS)
        .confirmsLaunchAgain(launching)
        // 读不出去向时不放那一排，原因在点"开始"时报
        .observing(services.store, id: leaf.id, into: $launch) { [id = leaf.id, here = services.hostID] store in
            guard case .launch(_, let host) = try store.handOffPlan(id, host: here).destination else {
                return MacAgents(hostID: "", agents: [], modifiedAt: .distantPast)
            }
            return try store.macAgents(on: host)
        }
        #endif
    }

    private func captioned(_ caption: String) -> some View {
        Text(caption).font(BubbleMetrics.meta).foregroundStyle(palette.ink2).lineLimit(1)
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
