#if os(macOS)
import AppKit
import CuePi
import CueStore
import SwiftUI

/// 打开时与回到 App 时重新检测这台的 Agent（用户可能刚在终端里登录了 Pi、装了 Node.js）；打开后第一次问完之前只写检测中：不先给勾选再在启用时报错。
/// 每行写它会写什么或做什么，点按钮就是同意。
struct SetupPanel: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var checked = false
    @State private var here: MacAgents?
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
    private var cueRowShown: Bool { setupCue == .enable || waiting != nil }
    private var waiting: String? { if case .waiting(let why) = setupCue { why } else { nil } }
    private var enablingCue: Bool { setupCue == .enable && !skipsCue }
    private var hasChoices: Bool { checked && (rows.contains { $0.step == .connect } || cueRowShown) }
    private var logsInFirst: Bool {
        rows.contains { if case .logIn = $0.step { true } else { $0.step == .loggingIn } }
    }
    private var done: Bool { checked && rows.isEmpty && !cueRowShown }
    private var tidying: AgentLibrary? {
        guard done, let library = workspace.library, library.hostID == services.hostID, !library.automaticOrders.isEmpty else { return nil }
        return library
    }
    @State private var tidyingNow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, Spacing.panel).padding(.top, Spacing.panel)
            // 不用 Form：浮层里的 Form 给开关报错位置、没有按下动作，读屏与辅助控制点不中（macOS 27 实测），这里按设置窗口的样子自己排
            VStack(alignment: .leading, spacing: Spacing.group) { content }
                .font(Typography.body)
                .labeledContentStyle(RowLayout())
                .labelStyle(RowLabel())
                .controlSize(.mini)
                .padding(.horizontal, Spacing.panel).padding(.vertical, Spacing.block)
            footer.padding(.horizontal, Spacing.panel).padding(.bottom, Spacing.panel)
        }
        .frame(width: 520)
        .animation(Motion.fade, value: checked)
        .onAppear { withAnimation(Motion.fading(Motion.nudge, reduceMotion: reduceMotion)) { shown = true } }
        .observing(services.store, into: $here, onError: workspace.fail) { [host = services.hostID] in try $0.macAgents(on: host) }
        .task {
            let activations = NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification)  // 第一次检测途中切回来的也要再测
            await workspace.recheckAgents()
            checked = true
            for await _ in activations { await workspace.recheckAgents() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.block) {
            Image(decorative: Mascot.hello.rawValue).resizable().scaledToFit().frame(width: 64, height: 64)
                .scaleEffect(shown || reduceMotion ? 1 : 0.9)
                .opacity(shown ? 1 : 0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(tidying != nil ? "把技能与规则收到一处" : setupCue == .none ? "接入 Agent" : "启用 \(cueName)")
                    .font(Typography.heading).foregroundStyle(palette.ink)
                if tidying != nil {
                    Text("各家读同一份技能与规则，改一处就都改了").font(Typography.secondary).foregroundStyle(palette.ink2)
                } else if setupCue != .none {
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
                Text(logsInFirst ? "先登录好其中一家" : "先装好其中一家").font(Typography.secondary).foregroundStyle(palette.ink2)
                    .padding(.horizontal, Spacing.tight)
            }
            if !rows.isEmpty { group { ForEach(rows) { row($0) } } }
            if cueRowShown { group { cueRow } }
            if let tidying {
                SetupLibraryStep(library: tidying)
            } else if done {
                note { Text("都已接入") }
            }
        }
    }

    private func note(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: Spacing.item) { content() }.foregroundStyle(palette.ink2)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Spacing.inset).padding(.vertical, Spacing.item)
            .background(palette.paper, in: .rect(cornerRadius: Radius.block))
    }

    private func row(_ row: SetupRow) -> some View {
        let kind = row.kind
        let (tone, line, busy) = describe(row)
        return SettingRow(title: .verbatim(kind.name), icon: kind.mark.image, tone: tone, busy: busy, status: line, help: nil) {
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
                action(kind.facts.loginArguments == nil ? "打开终端" : "登录", kind) { await workspace.logIn(kind) }
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
        case .checking: return (.calm, Dotted(String(localized: "检查中…")), true)
        case .install(let failure?): return (.failure, Dotted(AgentLine.notInstalled(failure)), false)
        case .logIn(let failure?): return (.failure, Dotted(failure), false)
        case .install: return (.calm, Dotted(kind == .claudeCode ? String(localized: "推荐") : nil, String(localized: "运行官方安装脚本")), false)
        case .needs(let prerequisite): return (.notice, Dotted(AgentLine.needs(prerequisite)), false)
        case .installing: return (.calm, Dotted(AgentLine.installing), true)
        case .logIn:
            let how = kind.facts.loginArguments == nil ? String(localized: "在 \(kind.name) 里输入 /login") : String(localized: "在浏览器里登录")
            return (.calm, Dotted(how), false)
        case .loggingIn: return (.calm, Dotted(String(localized: "在浏览器里登录完回到这里")), true)
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

    private func action(_ title: LocalizedStringResource, _ kind: AgentKind, _ run: @escaping () async -> Void) -> some View {
        Button(title) { Task { await run() } }
            .buttonStyle(ControlButtonStyle(kind: .secondary))
            .accessibilityLabel("\(String(localized: title)) \(kind.name)")
    }

    private var cueRow: some View {
        let waiting = self.waiting
        let (tone, line): (StatusTone, Dotted?) = failures.cue.map { (.failure, Dotted($0)) }
            ?? (.calm, waiting.map { Dotted($0) } ?? Dotted(folder).nonEmpty)
        return SettingRow(
            title: "在这台 Mac 上启用", icon: Image(.cue), tone: tone, busy: waiting != nil || working && enablingCue, status: line, help: nil
        ) {
            check(String(localized: "在这台 Mac 上启用 \(cueName)"), isOn: Binding(get: { waiting == nil && !skipsCue }, set: { skipsCue = !$0 }))
                .disabled(waiting != nil)
        } fix: {
            EmptyView()
        }
    }

    private var folder: String? {
        guard let home = workspace.catalog?.project(Project.defaultID), workspace.catalog?.directories[home.id] == nil else { return nil }
        return String(localized: "任务在 \(workspace.pendingFolder(of: home)) 里做")
    }

    private func check(_ name: String, isOn: Binding<Bool>) -> some View {
        Toggle(name, isOn: isOn).labelsHidden().toggleStyle(.checkbox).disabled(working)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: Spacing.group) {
            Text(tidying != nil ? "做完能撤销；原来的那些进废纸篓" : "可在设置里改").font(Typography.meta).foregroundStyle(palette.ink3)
            Spacer(minLength: 8)
            if let tidying {
                Button("跳过") { close() }
                    .buttonStyle(ControlButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button {
                    tidyingNow = true
                    Task {
                        await workspace.tidy(tidying.automaticOrders, in: tidying)
                        close()
                    }
                } label: {
                    TidyLabel(title: "一键整理", working: tidyingNow)
                }
                .buttonStyle(ControlButtonStyle(kind: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(tidyingNow)
            } else if done {
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

    private var primaryTitle: LocalizedStringResource {
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
            if failures.isEmpty, tidying == nil { close() }
        }
    }

    private func group(@ViewBuilder _ rows: () -> some View) -> some View {
        VStack(spacing: 0) {
            Group(subviews: rows()) { subviews in
                ForEach(subviews) { row in
                    row.padding(.horizontal, Spacing.inset).padding(.vertical, Spacing.item)
                }
            }
        }
        .rowPaper(cornerRadius: Radius.block)
    }
}

private struct RowLayout: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: Spacing.group) {
            configuration.label
            Spacer(minLength: 0)
            configuration.content
        }
    }
}

private struct RowLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
            configuration.icon
            VStack(alignment: .leading, spacing: Spacing.hair) { configuration.title }
        }
    }
}
#endif
