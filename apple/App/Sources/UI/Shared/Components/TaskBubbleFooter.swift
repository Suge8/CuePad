import CueStore
import SwiftUI

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
                // 是哪一步、它此刻的状态词，上面的子任务行已经写了：这一条不再写它的名字
                if let step = data.steps.first(where: { $0.piSessionID == session.sessionID }) { AgentStrip(leaf: step) }
            case .start(let leaf)?: StartBar(leaf: leaf, caption: leaf.title, editing: nil)
            case nil: EmptyView()
            }
        } else if agents.items[focus.id] != nil {
            AgentStrip(leaf: focus)
        } else if let kind = agents.launching[focus.id] {
            LaunchStrip(kind: kind)
        } else if focus.status != .done {
            StartBar(leaf: focus, caption: nil, editing: editing)
        }
    }
}

/// 正在开会话的叶子：与会话连上后的那一行（`AgentStrip`）同一种排法、同一个位置，写正在开哪家的会话；连上后原地换成它。
/// 开得慢时（Claude Code 冷启动、第一句落进会话，实测 9–17 秒）这里一直有字，不是一片空白。
private struct LaunchStrip: View {
    let kind: AgentKind
    @Environment(\.palette) private var palette

    var body: some View {
        BubbleStrip(mark: kind.mark.image) {
            HStack(spacing: 6) {
                Spinner(.small)
                Text("正在开 \(kind.name) 会话…").font(BubbleMetrics.strong).foregroundStyle(palette.ink).lineLimit(1)
            }
        } trailing: {
            // 与"去会话"同高：连上后换成它时这一行不跳
            Color.clear.frame(width: 0, height: BubbleMetrics.capsule)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 交给了会话的叶子此刻怎样（`TaskAgentLook`，两端同一份说法）：开头是这家 Agent 的标志（不用吉祥物，它是 Cue 的样子），
/// 状态标（`PiStateDot`，在做时是心电线）接一句标题，下面一句进展或原因；整条点了去会话。
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
            let look = TaskAgentLook(shown, line: PiProgress.note(of: state, failure: shown.undelivered?.text(sync: workspace.services.syncStatus)))
            Button { workspace.openSession(state.id, sessionID: state.sessionID) } label: { strip(look, shown: shown, session: state) }
                .buttonStyle(PressStyle(.wide))
                .accessibilityElement(children: .combine)
                .accessibilityHint("打开会话")
        }
    }

    private func strip(_ look: TaskAgentLook, shown: PiShown, session: PiSessionState) -> some View {
        // 同看板的会话卡（`BoardSessionCard`）：认得出是哪家就是它的标志，认不出是终端
        BubbleStrip(mark: session.agent.known?.mark.image ?? Image(.terminal), markLabel: session.agentMark) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    PiStateDot(shown: shown, size: BubbleMetrics.dot).relaySpot(session: session.sessionID, row: .task)
                    Text(look.title).font(BubbleMetrics.strong).foregroundStyle(palette.ink).lineLimit(1)
                }
                if let note = look.note {
                    Text(note).font(BubbleMetrics.meta).foregroundStyle(palette.ink2).lineLimit(2)
                }
            }
        } trailing: {
            Text("去会话").font(BubbleMetrics.meta.weight(.semibold))
                .foregroundStyle(shown.needsYou ? palette.onFill : palette.ink)
                .padding(.horizontal, 14).frame(height: BubbleMetrics.capsule)
                .background(shown.needsYou ? palette.signatureFill : palette.fill, in: .capsule)
        }
    }
}

/// 气泡底下会话那一行的排法（`AgentStrip`、`LaunchStrip`）：左边这家 Agent 的标志，中间状态与说明，右边可选的动作。
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
        .background(palette.fill, in: .rect(cornerRadius: BubbleMetrics.stripRadius, style: .continuous))
        .contentShape(.rect)
    }
}

/// 还没交出去的叶子："开始"——正文连同标题作为第一句交给 Agent（先写下正文里没保存的字）。Mac 左边另有"绑定会话"；
/// 这台 Mac 上上次没开成（`Workspace.launchFailures`）时左边换成原因、按钮写"重试"。
private struct StartBar: View {
    let leaf: Card
    /// 有子任务的任务开的是哪一步。
    let caption: String?
    let editing: CardEditing?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: BubbleMetrics.gap) {
            #if os(macOS)
            if let failure {
                Text(failure).font(BubbleMetrics.meta).foregroundStyle(palette.failure).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if caption == nil {
                Menu { SessionBindItems(leaf: leaf) } label: {
                    Text("绑定会话").font(BubbleMetrics.meta).foregroundStyle(palette.ink3)
                }
                .menuStyle(.button).buttonStyle(PressStyle(.inline)).menuIndicator(.hidden).fixedSize()
            }
            #endif
            if let caption { Text(caption).font(BubbleMetrics.meta).foregroundStyle(palette.ink2).lineLimit(1) }
            Spacer(minLength: 0)
            Button(action: start) {
                Label(failure != nil ? "重试" : caption == nil ? "开始" : "开始这一步", icon: .start)
                    .font(BubbleMetrics.meta.weight(.semibold)).foregroundStyle(palette.onFill)
                    .padding(.horizontal, 16).frame(height: BubbleMetrics.capsule)
                    .background(palette.signatureFill, in: .capsule).contentShape(.capsule)
            }
            .buttonStyle(PressStyle())
            .accessibilityHint("把任务的正文交给 Agent，开始做")
        }
    }

    private var failure: String? {
        #if os(macOS)
        workspace.launchFailures[leaf.id]
        #else
        nil
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
