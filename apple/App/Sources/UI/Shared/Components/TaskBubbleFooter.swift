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
        case start(Card, caption: String?, editing: CardEditing?)
    }

    private var stage: Stage? {
        if focus.id == data.goal.id, !data.steps.isEmpty {
            switch workspace.lead(of: data.steps, in: agents) {
            case .agent(_, let session)?: return data.steps.first { $0.piSessionID == session.sessionID }.map(Stage.agent)
            case .start(let leaf)?: return .start(leaf, caption: leaf.title, editing: nil)
            case nil: return nil
            }
        }
        if agents.items[focus.id] != nil { return .agent(focus) }
        if let kind = agents.launching[focus.id], !workspace.launchUnsettled(focus.id) { return .launching(kind) }
        return focus.status != .done ? .start(focus, caption: nil, editing: editing) : nil
    }

    /// 开始 → 正在开 → Agent 在做是同一条的三个样子，里面的旧的先淡完、新的再淡入（`handOff`），不叠着换。
    /// 同新会话输入框的工具排：不垫底、不画线，Mac 上铺满气泡的宽（那一排的字才写得全），靠上面留的空隔开。
    var body: some View {
        if let stage {
            ZStack(alignment: .leading) {
                switch stage {
                case .agent(let leaf): AgentStrip(leaf: leaf).transition(.handOff)
                case .launching(let kind): LaunchStrip(kind: kind).transition(.handOff)
                case .start(let leaf, let caption, let editing): StartBar(leaf: leaf, caption: caption, editing: editing).transition(.handOff)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Spacing.tight)
        }
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
                .buttonStyle(ControlButtonStyle(kind: .primary, size: .regular))
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
