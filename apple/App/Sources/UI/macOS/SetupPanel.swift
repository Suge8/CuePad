#if os(macOS)
import AppKit
import CuePi
import CueStore
import SwiftUI

/// 接入 Agent 并启用 Cue，一处做完：首次打开出现一次（`Workspace.offerSetup`），Cue 页的启用钮（`CueWelcome`）、会话页的"接入"也打开它；之后在设置里逐个开关。
/// 打开时与回到 App 时重新检测这台的 Agent、问它们能不能用（`Workspace.recheckAgents`：用户可能刚在终端里登录了 Pi、装了 Node.js），
/// 打开后第一次问完之前只写检测中：没登录的那家一出来就是"登录"，不先给勾选再在启用时报错。
/// Agent 那几行与 Cue 那一行只读 `Workspace.setupRows`、`setupCue`：能当 Cue 的一家都用不了时，一行一个按钮（安装、登录），
/// 装、登录都在后台做、就地写进度与原因，不用开终端粘命令；平时是勾选要接入的几家。每行写它会写什么或做什么，点按钮就是同意。
/// 没做成的那一行写原因，都做成就收起。"以后再说"关掉就是不接。
struct SetupPanel: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    /// 打开后第一次检测、问完了
    @State private var checked = false
    /// 这台写下的各家能不能用（读库）
    @State private var here: MacAgents?
    /// 去掉勾的几家与 Cue 那一行（面板开着时的选择，不存）
    @State private var skipped: Set<AgentKind> = []
    @State private var skipsCue = false
    @State private var working = false
    @State private var failures = SetupFailures()

    private var agents: AgentIntegrations { services.agents }
    private var mac: MacAgents { here ?? MacAgents(hostID: services.hostID, agents: [], modifiedAt: .distantPast) }
    private var rows: [SetupRow] { workspace.setupRows(here: mac) }
    private var chosen: [AgentKind] { rows.filter { $0.step == .connect && !skipped.contains($0.kind) }.map(\.kind) }
    private var cueName: String { workspace.cue.name }
    private var setupCue: Workspace.SetupCue { workspace.setupCue(here: mac) }
    /// 列出 Cue 那一行：能勾的，或在等 iCloud 的。
    private var cueRowShown: Bool { setupCue == .enable || waiting != nil }
    private var waiting: String? { if case .waiting(let why) = setupCue { why } else { nil } }
    private var enablingCue: Bool { setupCue == .enable && !skipsCue }
    /// 检测完了，有可勾的：要接入的几家或 Cue 那一行。
    private var hasChoices: Bool { checked && (rows.contains { $0.step == .connect } || cueRowShown) }
    /// 有一家装好了只差登录（提示写"先登录"，否则写"先装"）。
    private var logsInFirst: Bool {
        rows.contains { if case .logIn = $0.step { true } else { $0.step == .loggingIn } }
    }
    private var done: Bool { checked && rows.isEmpty && !cueRowShown }

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
        .animation(HandOff.quick, value: checked)
        .onAppear { withAnimation(reduceMotion ? HandOff.quick : Motion.snappy) { shown = true } }
        .observing(services.store, into: $here, onError: workspace.fail) { [host = services.hostID] in try $0.macAgents(on: host) }
        .task {
            await workspace.recheckAgents()
            checked = true
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) { await workspace.recheckAgents() }
        }
    }

    /// 标题说这一步做成什么；要启用 Cue 时下面一句说它是什么（第一次打开的人只认得 Agent）。
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(Mascot.hello.rawValue).resizable().scaledToFit().frame(width: 64, height: 64)
                .scaleEffect(shown || reduceMotion ? 1 : 0.9)
                .opacity(shown ? 1 : 0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(setupCue == .none ? "接入 Agent" : "启用 \(cueName)").font(Typography.heading).foregroundStyle(palette.ink)
                if setupCue != .none {
                    Text("你说一件事，\(cueName) 交给这台 Mac 上的 Agent 去做").font(Typography.secondary).foregroundStyle(palette.ink2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var content: some View {
        if !checked {
            note { Spinner(.small); Text("正在检测 Agent…") }
        } else {
            if setupCue == .needsAgent {
                Text("先\(logsInFirst ? "登录" : "装")好其中一家").font(Typography.secondary).foregroundStyle(palette.ink2)
                    .padding(.horizontal, 4)
            }
            // Agent 那几行与 Cue 那一行分两组：先定接哪几家，再是启用这一步
            if !rows.isEmpty { group { ForEach(rows) { row($0) } } }
            if cueRowShown { group { cueRow } }
            if done { note { Text("都已接入") } }
        }
    }

    /// 一行一句的提示（检测中、都已接入）：纸色底。
    private func note(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 8) { content() }.foregroundStyle(palette.ink2)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
            .background(palette.paper, in: .rect(cornerRadius: 10, style: .continuous))
    }

    /// 一家一行：这一步写什么、右边放什么（勾选、安装、登录）。
    private func row(_ row: SetupRow) -> some View {
        let kind = row.kind
        let (tone, line, busy) = describe(row)
        return SettingRow(title: kind.name, icon: kind.mark.image, tone: tone, busy: busy, status: line, help: nil) {
            switch row.step {
            case .connect:
                check(kind.name, isOn: Binding(
                    get: { !skipped.contains(kind) },
                    set: { if $0 { skipped.remove(kind) } else { skipped.insert(kind) } }))
            case .install(let failure):
                action(failure == nil ? "安装" : "重试", kind) { await workspace.installAgent(kind) }
            case .needs(let prerequisite):
                Link("去官网", destination: prerequisite.site)
                    .buttonStyle(ControlButtonStyle(kind: .secondary))
                    .accessibilityLabel("\(prerequisite.name) 官网")
            case .logIn:
                action(kind.loginArguments == nil ? "打开终端" : "登录", kind) { await workspace.logIn(kind) }
            case .loggingIn:
                action("重新登录", kind) { await workspace.logIn(kind) }
            case .checking, .installing, .problem:
                EmptyView()
            }
        } fix: {
            EmptyView()
        }
    }

    private func describe(_ row: SetupRow) -> (StatusTone, Dotted?, Bool) {
        let kind = row.kind
        switch row.step {
        case .connect:
            let (tone, line) = failures.agents[kind].map { (StatusTone.failure, Dotted($0)) }
                ?? unusable(kind).map { (StatusTone.notice, Dotted($0)) }
                ?? AgentLine.of(kind, agents.status(kind), writable: agents.isWritable(kind))
            return (tone, line, working && chosen.contains(kind))
        case .checking: return (.calm, "检查中…", true)
        case .install(let failure?): return (.failure, Dotted("没装上", failure), false)  // 原因是安装脚本的最后一句原话
        case .logIn(let failure?): return (.failure, Dotted(failure), false)
        case .install: return (.calm, Dotted(kind == .claudeCode ? "推荐" : nil, "运行官方安装脚本"), false)
        case .needs(let prerequisite):
            return (.notice, Dotted("需要 \(prerequisite.name) \(prerequisite.minimum.major).\(prerequisite.minimum.minor) 以上"), false)
        case .installing: return (.calm, "安装中，可能要几分钟", true)
        case .logIn: return (.calm, kind.loginArguments == nil ? "在 \(kind.name) 里输入 /login" : "在浏览器里登录", false)
        case .loggingIn: return (.calm, "在浏览器里登录完回到这里", true)
        case .problem(let why): return (.notice, Dotted(why), false)
        }
    }

    /// 勾得上、却问不出能不能用的原因（只差接入不算）：接入照样写文件，但不写出来就像接上就能用。
    private func unusable(_ kind: AgentKind) -> String? {
        switch mac.problem(kind) {
        case nil, .notConnected?: nil
        case let reason?: reason.description
        }
    }

    private func action(_ title: String, _ kind: AgentKind, _ run: @escaping () async -> Void) -> some View {
        Button(title) { Task { await run() } }
            .buttonStyle(ControlButtonStyle(kind: .secondary))
            .accessibilityLabel("\(title) \(kind.name)")
    }

    /// 启用 Cue 那一行：默认项目还没有文件夹时写任务在哪做（工作区，第一次开工时建好，`Workspaces`）。没启用成的写原因。
    /// 在等 iCloud 时写在等什么、转圈，勾不上。
    private var cueRow: some View {
        let waiting = self.waiting
        let (tone, line): (StatusTone, Dotted?) = failures.cue.map { (.failure, Dotted($0)) }
            ?? (.calm, waiting.map { Dotted($0) } ?? Dotted(folder).nonEmpty)
        return SettingRow(
            title: "在这台 Mac 上启用", icon: Image(.cue), tone: tone, busy: waiting != nil || working && enablingCue, status: line, help: nil
        ) {
            check("在这台 Mac 上启用 \(cueName)", isOn: Binding(get: { waiting == nil && !skipsCue }, set: { skipsCue = !$0 }))
                .disabled(waiting != nil)
        } fix: {
            EmptyView()
        }
    }

    private var folder: String? {
        guard let home = workspace.catalog?.project(Project.defaultID), workspace.catalog?.directories[home.id] == nil else { return nil }
        return "任务在 \(Workspaces.shown(services.workspaces.directory(for: home.name).path(percentEncoded: false))) 里做"
    }

    private func check(_ name: String, isOn: Binding<Bool>) -> some View {
        Toggle(name, isOn: isOn).labelsHidden().toggleStyle(.checkbox).disabled(working)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("可在设置里改").font(Typography.meta).foregroundStyle(palette.ink3)
            Spacer(minLength: 8)
            if done {
                Button("完成") { close() }
                    .buttonStyle(ControlButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("以后再说") { close() }
                    .buttonStyle(ControlButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                if hasChoices {
                    Button(primaryTitle) { setUp() }
                        .buttonStyle(ControlButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || chosen.isEmpty && !enablingCue)
                }
            }
        }
    }

    private var primaryTitle: String {
        if working { return enablingCue ? "启用中…" : "接入中…" }
        if chosen.isEmpty { return cueRowShown ? "启用" : "接入" }
        return enablingCue ? "接入并启用" : "接入"
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
