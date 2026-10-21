import CueEditor
import CueStore
import CueText
import SwiftUI

/// 气泡最下面"下一步"那一条。
struct BubbleFooter: View {
    let data: BubbleData
    let focus: Card
    let editing: CardEditing?
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents

    var body: some View {
        if focus.id == data.goal.id, !data.steps.isEmpty {
            switch workspace.lead(of: data.steps, in: agents) {
            case .agent(_, let session)?:
                if let step = data.steps.first(where: { $0.piSessionID == session.sessionID }) { AgentStrip(leaf: step, caption: step.title) }
            case .start(let leaf)?: StartBar(leaf: leaf, caption: leaf.title, editing: nil)
            case nil: EmptyView()
            }
        } else if agents.items[focus.id] != nil {
            AgentStrip(leaf: focus, caption: nil)
        } else if focus.status != .done, !agents.launching.contains(focus.id) {
            StartBar(leaf: focus, caption: nil, editing: editing)
        }
    }
}

/// 交给了会话的叶子此刻怎样（\`TaskAgentLook\`，两端同一份说法）：吉祥物（在做时轻轻浮动）、状态标与一句标题、一句进展；整条点了去会话。
private struct AgentStrip: View {
    let leaf: Card
    /// 有步骤的任务看的是哪一步（写在进展前面）。
    let caption: String?
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents
    @Environment(\.palette) private var palette
    @Environment(\.closePanel) private var close
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        if let item = agents.items[leaf.id] {
            #if os(macOS)
            let state = workspace.withLiveState(item.state)
            #else
            let state = item.state
            #endif
            let shown = workspace.shown(state, delivery: item.delivery)
            let look = TaskAgentLook(shown, line: PiProgress.note(of: state, failure: shown.undelivered?.text(sync: workspace.services.syncStatus)))
            Button { open(shown, state) } label: { strip(look, shown: shown, session: state.sessionID) }
                .buttonStyle(PressStyle(.wide))
                .accessibilityElement(children: .combine)
                .accessibilityHint("打开会话")
        }
    }

    private func strip(_ look: TaskAgentLook, shown: PiShown, session: String) -> some View {
        HStack(spacing: BubbleMetrics.gap) {
            MascotFace(mascot: look.mascot, floats: look.floats && !reduceMotion)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    PiStateDot(shown: shown, size: BubbleMetrics.dot).relaySpot(session: session, row: .task)
                    Text(look.title).font(BubbleMetrics.strong).foregroundStyle(palette.ink).lineLimit(1)
                }
                if let line = Dotted(caption, look.note).nonEmpty {
                    Text(line).font(BubbleMetrics.meta).foregroundStyle(palette.ink2).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Text("去会话").font(BubbleMetrics.meta.weight(.semibold))
                .foregroundStyle(shown.needsYou ? palette.onFill : palette.ink)
                .padding(.horizontal, 14).frame(height: BubbleMetrics.capsule)
                .background(shown.needsYou ? palette.signatureFill : palette.fill, in: .capsule)
        }
        .padding(BubbleMetrics.stripPadding)
        .background(palette.fill, in: .rect(cornerRadius: BubbleMetrics.stripRadius, style: .continuous))
        .contentShape(.rect)
    }

    private func open(_ shown: PiShown, _ session: PiSessionState) {
        #if os(macOS)
        workspace.show(.session(session.sessionID))
        #else
        close()
        navigation.follow(.agent(shown, session: session), store: services.store)
        #endif
    }
}

/// 还没交出去的叶子："开始"——正文连同标题作为第一句交给 Agent（先写下正文里没保存的字）。Mac 左边另有"绑定会话"。
private struct StartBar: View {
    let leaf: Card
    /// 有步骤的任务开的是哪一步。
    let caption: String?
    let editing: CardEditing?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.closePanel) private var close
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        HStack(spacing: BubbleMetrics.gap) {
            #if os(macOS)
            if caption == nil {
                Menu { SessionBindItems(leaf: leaf) } label: {
                    Text("绑定会话").font(BubbleMetrics.meta).foregroundStyle(palette.ink3)
                }
                .menuStyle(.button).buttonStyle(PressStyle(.inline)).menuIndicator(.hidden).fixedSize()
            }
            #endif
            if let caption { Text(caption).font(BubbleMetrics.meta).foregroundStyle(palette.ink2).lineLimit(1) }
            Spacer(minLength: 0)
            Button(action: start) {
                Label(caption == nil ? "开始" : "开始这一步", icon: .start)
                    .font(BubbleMetrics.meta.weight(.semibold)).foregroundStyle(palette.onFill)
                    .padding(.horizontal, 16).frame(height: BubbleMetrics.capsule)
                    .background(palette.signatureFill, in: .capsule).contentShape(.capsule)
            }
            .buttonStyle(PressStyle())
            .accessibilityHint("把任务的正文交给 Agent，开始做")
        }
    }

    private func start() {
        let workspace = workspace, editing = editing, leaf = leaf
        #if os(iOS)
        let navigation = navigation
        close()
        #endif
        Task {
            do {
                let card = try await editing?.flushed() ?? leaf
                #if os(macOS)
                workspace.handOff(card)
                #else
                navigation.handToAgent(card)
                #endif
            } catch {
                workspace.fail(error)
            }
        }
    }
}

/// 吉祥物的小像：透明底的图；在做时轻轻上下浮动（Core Animation，\`LoopLayer.float\`）。
private struct MascotFace: View {
    let mascot: Mascot
    let floats: Bool

    var body: some View {
        Group {
            if floats, let image = mascot.bitmap(side: BubbleMetrics.mascot) {
                LoopLayer(kind: .float(image, lift: BubbleMetrics.mascot * 0.06), color: .clear)
            } else {
                Image(mascot.rawValue).resizable().scaledToFit()
            }
        }
        .frame(width: BubbleMetrics.mascot, height: BubbleMetrics.mascot)
        .accessibilityHidden(true)
    }
}
