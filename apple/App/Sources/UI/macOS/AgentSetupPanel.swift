#if os(macOS)
import CueStore
import SwiftUI

extension Workspace {
    /// 首次打开：这台 Mac 上全部检测完、一家都没接入过、有能接的（`AgentIntegrations.needsSetup`），而面板还没出现过，就弹出它，只这一次。
    /// "出现过"记在 `AppSettings.agentSetupShown`：看过不接的人身上没有别的事实留下来，推不出。
    func offerAgentSetup() async {
        let agents = services.agents
        for await count in Observations({ agents.statuses.count }) where count == AgentKind.allCases.count { break }
        guard !services.settings.agentSetupShown, agents.needsSetup else { return }
        services.settings.agentSetupShown = true
        showsAgentSetup = true
    }
}

/// 接入 Agent：首次打开出现一次（`Workspace.offerAgentSetup`），侧栏的接入小卡也打开它；之后在设置里逐个开关。
/// 列出这台 Mac 上检测到、还没接入的几家（`AgentIntegrations.connectable`），默认全选，"接入"一次装好选中的（同设置里打开开关）；
/// 点"接入"就是同意，每家写什么写在它那一行。没装上的那一行写原因，全装上就收起。"以后再说"关掉就是不接。
struct AgentSetupPanel: View {
    @Environment(AppServices.self) private var services
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    /// 去掉勾的几家（面板开着时的选择，不存）
    @State private var skipped: Set<AgentKind> = []
    @State private var working = false
    @State private var failures: [AgentKind: String] = [:]

    private var kinds: [AgentKind] { services.agents.connectable }
    private var chosen: [AgentKind] { kinds.filter { !skipped.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                Image(Mascot.hello.rawValue).resizable().scaledToFit().frame(width: 64, height: 64)
                    .scaleEffect(shown || reduceMotion ? 1 : 0.9)
                    .opacity(shown ? 1 : 0)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("接入 Agent").font(Typography.heading).foregroundStyle(palette.ink)
                    Text("接入后，终端和桌面版里的会话与历史也出现在 CuePad。Pi 要接入才能用。")
                        .font(Typography.secondary).foregroundStyle(palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24).padding(.top, 24)
            // 不用 Form：浮层里的 Form 给开关报错位置、没有按下动作，读屏与辅助控制点不中（macOS 27 实测），这里按设置窗口的样子自己排
            Group {
                if kinds.isEmpty {
                    Text("检测到的 Agent 都接入了").font(Typography.body).foregroundStyle(palette.ink2)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
                        .background(palette.paper, in: .rect(cornerRadius: 10, style: .continuous))
                } else {
                    group { ForEach(kinds) { row($0) } }
                }
            }
            .font(Typography.body)
            .labeledContentStyle(RowLayout())
            .labelStyle(RowLabel())
            .controlSize(.mini)
            .padding(.horizontal, 20).padding(.vertical, 16)
            HStack(alignment: .center, spacing: 12) {
                Text("之后在设置里随时改").font(Typography.meta).foregroundStyle(palette.ink3)
                Spacer(minLength: 8)
                if kinds.isEmpty {
                    Button("完成") { close() }
                        .buttonStyle(ControlButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("以后再说") { close() }
                        .buttonStyle(ControlButtonStyle(kind: .secondary))
                        .keyboardShortcut(.cancelAction)
                    Button(working ? "接入中…" : "接入") { connect() }
                        .buttonStyle(ControlButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || chosen.isEmpty)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
        .frame(width: 520)
        .background(palette.desk)
        .onAppear { withAnimation(reduceMotion ? Motion.quick : Motion.snappy) { shown = true } }
        .task { await services.agents.redetect() }
    }

    /// 一家一行：勾选、名字、会写什么（`AgentLine`），没装上的写原因。
    private func row(_ kind: AgentKind) -> some View {
        let (tone, line) = failures[kind].map { (StatusTone.failure, Dotted($0)) }
            ?? AgentLine.of(kind, services.agents.status(kind), writable: services.agents.isWritable(kind))
        return SettingRow(title: kind.name, icon: kind.mark.image, tone: tone, busy: working && chosen.contains(kind), status: line, help: nil) {
            Toggle(kind.name, isOn: Binding(
                get: { !skipped.contains(kind) },
                set: { if $0 { skipped.remove(kind) } else { skipped.insert(kind) } }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(working)
        } fix: {
            EmptyView()
        }
    }

    private func connect() {
        working = true
        let agents = services.agents, chosen = chosen
        Task {
            failures = await agents.install(chosen)
            working = false
            if failures.isEmpty { close() }
        }
    }

    /// 与设置窗口的分组同一种样子：纸色圆角底，行间一条细线。
    private func group(@ViewBuilder _ rows: () -> some View) -> some View {
        VStack(spacing: 0) {
            Group(subviews: rows()) { subviews in
                ForEach(subviews) { row in
                    row.padding(.horizontal, 12).padding(.vertical, 9)
                    if row.id != subviews.last?.id { Divider().padding(.leading, 12) }
                }
            }
        }
        .background(palette.paper, in: .rect(cornerRadius: 10, style: .continuous))
    }
}

/// 设置行（`SettingRow`）在 Form 外的排法，同 Form 里：名称在左、控件靠右。
private struct RowLayout: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
            Spacer(minLength: 0)
            configuration.content
        }
    }
}

/// 同 Form 里：图标一列，名称与它下面的状态上下排。
private struct RowLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
            VStack(alignment: .leading, spacing: 2) { configuration.title }
        }
    }
}
#endif
