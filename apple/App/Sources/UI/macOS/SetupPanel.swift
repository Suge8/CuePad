#if os(macOS)
import AppKit
import CuePi
import CueStore
import SwiftUI

extension Workspace {
    /// 首次打开：Cue 还没启用、面板还没出现过，就弹出它，只这一次（不等检测：检测中面板里写检测中）。
    /// "出现过"记在 `AppSettings.setupShown`：看过不接的人身上没有别的事实留下来，推不出。
    func offerSetup() {
        guard !services.settings.setupShown, !cue.canHear else { return }
        services.settings.setupShown = true
        showsSetup = true
    }

    /// 接入面板的主按钮：接入勾选的几家（同设置里打开开关），`enablingCue` 时再让 Cue 在这台 Mac 上启用（`AppServices.enableCue`），
    /// 启用了就去 Cue 页，接着就能对它说。接入有一家没装上不拦着启用：Cue 能用别家。
    func setUp(connecting kinds: [AgentKind], enablingCue: Bool) async -> SetupFailures {
        var failures = SetupFailures(agents: await services.agents.install(kinds))
        guard enablingCue else { return failures }
        do {
            try await services.enableCue(on: services.hostID)
            show(.cue)
        } catch CueEnableError.noRuntime(let why) {
            failures.cue = why
        } catch {
            failures.cue = error.localizedDescription
        }
        return failures
    }
}

/// 接入面板的主按钮没做成的：哪家没装上与原因、Cue 为什么没启用（这台 Mac 上的 Agent 都在这里，只写各家为什么）。
struct SetupFailures: Equatable {
    var agents: [AgentKind: String] = [:]
    var cue: String?

    var isEmpty: Bool { agents.isEmpty && cue == nil }
}

/// 接入 Agent 并启用 Cue，一处做完：首次打开出现一次（`Workspace.offerSetup`），Cue 页的启用卡、会话页的"接入"也打开它；之后在设置里逐个开关。
/// 打开时重新检测这台 Mac 上的 Agent（检测完之前只写检测中），回到 App 时再测一次（用户可能刚照着装法在终端里装好）。
/// 列出检测到、还没接入的几家（`AgentIntegrations.connectable`）与"在这台 Mac 上启用 Cue"那一行（Cue 哪台都没启用时），默认全选；
/// 每行写它会写什么、会做什么，点主按钮就是同意（`Workspace.setUp`）。一家能当 Cue 的 Agent 都没有时，Cue 那一行换成各家的安装命令。
/// 没做成的那一行写原因，都做成就收起。"以后再说"关掉就是不接。
struct SetupPanel: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    /// 去掉勾的几家与 Cue 那一行（面板开着时的选择，不存）
    @State private var skipped: Set<AgentKind> = []
    @State private var skipsCue = false
    @State private var working = false
    @State private var failures = SetupFailures()

    private var agents: AgentIntegrations { services.agents }
    private var kinds: [AgentKind] { agents.connectable }
    private var chosen: [AgentKind] { kinds.filter { !skipped.contains($0) } }
    private var cueName: String { workspace.cue.name }
    /// 这台 Mac 上有没有能当 Cue 的 Agent（`CueProfile.runtimes` 里有一家装着）。
    private var hasRuntime: Bool { CueProfile.runtimes.contains { agents.status($0)?.isAvailable == true } }
    /// 列出 Cue 那一行：哪台都没启用（在别的 Mac 上运行的不从这里换过来），这台也有能当它的 Agent。
    private var offersCue: Bool { !workspace.cue.canHear && hasRuntime }
    private var enablingCue: Bool { offersCue && !skipsCue }
    /// 有可勾的行：还没接入的几家或 Cue 那一行。
    private var hasRows: Bool { !kinds.isEmpty || offersCue }
    /// Cue 哪台都没启用，这台却一家能当它的 Agent 都没装：给装法。
    private var needsAgent: Bool { agents.detected && !hasRuntime && !workspace.cue.canHear }
    /// 检测完了，没有要做的。
    private var done: Bool { agents.detected && !hasRows && !needsAgent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 24).padding(.top, 24)
            // 不用 Form：浮层里的 Form 给开关报错位置、没有按下动作，读屏与辅助控制点不中（macOS 27 实测），这里按设置窗口的样子自己排
            VStack(alignment: .leading, spacing: 12) { content }
                .font(Typography.body)
                .labeledContentStyle(RowLayout())
                .labelStyle(RowLabel())
                .controlSize(.mini)
                .padding(.horizontal, 20).padding(.vertical, 16)
            footer.padding(.horizontal, 24).padding(.bottom, 20)
        }
        .frame(width: 520)
        .background(palette.desk)
        .animation(Motion.quick, value: agents.detected)
        .onAppear { withAnimation(reduceMotion ? Motion.quick : Motion.snappy) { shown = true } }
        .task {
            await agents.redetect()
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) { await agents.redetect() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(Mascot.hello.rawValue).resizable().scaledToFit().frame(width: 64, height: 64)
                .scaleEffect(shown || reduceMotion ? 1 : 0.9)
                .opacity(shown ? 1 : 0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.cue.canHear ? "接入 Agent" : "接入 Agent，启用 \(cueName)").font(Typography.heading).foregroundStyle(palette.ink)
                Text(workspace.cue.canHear
                    ? "接入后，终端和桌面版里的会话与历史也出现在 CuePad。"
                    : "\(cueName) 用这台 Mac 上的 Agent 替你开会话做事；接入后，终端和桌面版里的会话与历史也出现在 CuePad。")
                    .font(Typography.secondary).foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !agents.detected {
            HStack(spacing: 8) {
                Spinner(.small)
                Text("正在检测这台 Mac 上的 Agent…").foregroundStyle(palette.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
            .background(palette.paper, in: .rect(cornerRadius: 10, style: .continuous))
        } else {
            if hasRows {
                group {
                    ForEach(kinds) { row($0) }
                    if offersCue { cueRow }
                }
            }
            if needsAgent { guide }
            if done {
                Text("检测到的 Agent 都接入了").foregroundStyle(palette.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
                    .background(palette.paper, in: .rect(cornerRadius: 10, style: .continuous))
            }
        }
    }

    /// 一家一行：勾选、名字、会写什么（`AgentLine`），没装上的写原因。
    private func row(_ kind: AgentKind) -> some View {
        let (tone, line) = failures.agents[kind].map { (StatusTone.failure, Dotted($0)) }
            ?? AgentLine.of(kind, agents.status(kind), writable: agents.isWritable(kind))
        return SettingRow(title: kind.name, icon: kind.mark.image, tone: tone, busy: working && chosen.contains(kind), status: line, help: nil) {
            check(kind.name, isOn: Binding(
                get: { !skipped.contains(kind) },
                set: { if $0 { skipped.remove(kind) } else { skipped.insert(kind) } }))
        } fix: {
            EmptyView()
        }
    }

    /// 启用 Cue 那一行：它会做什么；默认项目还没有文件夹时写它第一次开工时建在哪（`Workspaces`）。没启用成的写原因。
    private var cueRow: some View {
        let (tone, line) = failures.cue.map { (StatusTone.failure, Dotted($0)) } ?? (StatusTone.calm, Dotted("用这里的 Agent 替你开会话", folder))
        return SettingRow(title: "在这台 Mac 上启用 \(cueName)", icon: Image(.cue), tone: tone, busy: working && enablingCue, status: line, help: nil) {
            check("在这台 Mac 上启用 \(cueName)", isOn: Binding(get: { !skipsCue }, set: { skipsCue = !$0 }))
        } fix: {
            EmptyView()
        }
    }

    private var folder: String? {
        guard let home = workspace.catalog?.project(Project.defaultID), workspace.catalog?.directories[home.id] == nil else { return nil }
        let workspaces = services.workspaces
        return "开工时建好 \(workspaces.shown(workspaces.directory(for: home.name).path(percentEncoded: false)))"
    }

    private func check(_ name: String, isOn: Binding<Bool>) -> some View {
        Toggle(name, isOn: isOn).labelsHidden().toggleStyle(.checkbox).disabled(working)
    }

    /// 一家能当 Cue 的 Agent 都没装：各家一行安装命令（`InstallCommand`，Pi 太旧时是升级命令），装好回来就重新检测。
    private var guide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("这台 Mac 上还没有 \(cueName) 能用的 Agent，在终端里装一个：").font(Typography.secondary).foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(AgentKind.allCases.filter(CueProfile.runtimes.contains)) { kind in
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind.name).font(Typography.meta).foregroundStyle(palette.ink2)
                    InstallCommand(kind: kind, presence: agents.status(kind)?.presence ?? .notFound)
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(needsAgent ? "装好后回到 CuePad，这里会重新检测" : "之后在设置里随时改")
                .font(Typography.meta).foregroundStyle(palette.ink3)
            Spacer(minLength: 8)
            if done {
                Button("完成") { close() }
                    .buttonStyle(ControlButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("以后再说") { close() }
                    .buttonStyle(ControlButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                if hasRows {
                    Button(primaryTitle) { setUp() }
                        .buttonStyle(ControlButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || chosen.isEmpty && !enablingCue)
                }
            }
        }
    }

    private var primaryTitle: String {
        if working { return enablingCue ? "正在启用…" : "接入中…" }
        switch (chosen.isEmpty, enablingCue) {
        case (false, true): return "接入并启用"
        case (true, true): return "启用 \(cueName)"
        default: return "接入"
        }
    }

    private func setUp() {
        working = true
        let chosen = chosen, enablingCue = enablingCue
        Task {
            failures = await workspace.setUp(connecting: chosen, enablingCue: enablingCue)
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
