#if os(macOS)
import AppKit
import CuePi
import CueStore
import SwiftUI

extension Workspace {
    /// 首次打开：面板没出现过、Cue 从没在哪台 Mac 上设过（`CueProfile.hostID`，停用后仍留着），就弹出它，只这一次（不等检测与同步，面板里写在等什么）。
    /// 已接入 Agent、只差 Cue 的老用户也弹这一次，停用过 Cue 的不再打扰。"出现过"记在 `AppSettings.setupOffered`：看过不接的人身上没有别的事实留下来。
    func offerSetup() {
        guard !services.settings.setupOffered, cue.hostID == nil else { return }
        services.settings.setupOffered = true
        showsSetup = true
    }

    /// 接入面板里 Cue 那一行（`SetupPanel`）：什么时候有、能不能勾只在这里定。检测完、问过这台的 Agent 之后读（之前面板只写检测中）。
    enum SetupCue: Equatable {
        /// Cue 已启用（这台或别的 Mac）：没有这一行，面板只管接入
        case none
        /// 这台的库还没和 iCloud 对过一遍（`CueGate.waiting`，换新 Mac 时）：Cue 也许已在别的 Mac 上设过，
        /// 先不提议在这台启用，免得把它从那台抢过来；写 `why`
        case waiting(String)
        /// 能当 Cue 的 Agent（`CueProfile.runtimes`）这台一家都用不了：带着装、登录的那几行（`setupRows`）
        case needsAgent
        /// 能勾：在这台启用
        case enable
    }

    /// `here` 是这台写下的各家能不能用（`CueStore.macAgents`）。能当 Cue 的有一家能用、或只差接入（勾上接入、同一下启用）就能启用。
    func setupCue(here: MacAgents) -> SetupCue {
        switch CueGate.of(services, running: cue.canHear ? cue.hostID : nil, name: cue.hostName) {
        case .runs: return .none
        case .waiting(let why): return .waiting(why)
        case .open:
            let connectable = services.agents.connectable
            let usable = CueProfile.runtimes.contains { here.kinds.contains($0) || here.problem($0) == .notConnected && connectable.contains($0) }
            return usable ? .enable : .needsAgent
        }
    }

    /// 接入面板的 Agent 那几行（只在这里推）：各家还要你做的那一步（`setupStep`），没事可做的不列。平时只列可勾的与要登录的；
    /// 能当 Cue 的一家都用不了时，能当 Cue 的几家平行列上，推荐的 Claude Code 排第一。
    func setupRows(here: MacAgents) -> [SetupRow] {
        let needsAgent = setupCue(here: here) == .needsAgent
        return Self.rowOrder.compactMap { kind in
            setupStep(kind, here: here).map { SetupRow(kind: kind, step: $0) }
        }.filter { $0.step.isActionable || needsAgent && CueProfile.runtimes.contains($0.kind) }
    }

    private static let rowOrder: [AgentKind] = [.claudeCode, .codex, .pi, .opencode]

    /// 一家这一步要你做什么，没有为 nil：在装、在登录的看 `AgentIntegrations.jobs`；没装是"安装"（缺前提时先装前提）；
    /// 探测说没登录是"登录"（Pi 没接入也问得出）；没接入是勾上接入；还没按装好后的样子问过是检查中；别的原因照写。
    private func setupStep(_ kind: AgentKind, here: MacAgents) -> SetupStep? {
        let agents = services.agents
        var failure: String?
        switch agents.jobs[kind] {
        case .installing: return .installing
        case .loggingIn: return .loggingIn
        case .failed(let why): failure = why
        case nil: break
        }
        guard let status = agents.status(kind) else { return .checking }
        guard status.isAvailable else { return status.lacking.map(SetupStep.needs) ?? .install(failure) }
        let problem = here.problem(kind)
        if problem == .notLoggedIn { return .logIn(failure) }
        if agents.connectable.contains(kind) { return .connect }
        switch problem {
        case nil, .notInstalled?: return failure.map(SetupStep.problem) ?? (here.kinds.contains(kind) ? nil : .checking)
        case let reason?: return .problem(reason.description)
        }
    }

    /// 装这一家（接入面板的"安装"）：后台跑官方安装脚本，装完再问一遍这台各家能不能用。
    func installAgent(_ kind: AgentKind) async {
        await services.agents.installAgent(kind)
        await recheckAgents()
    }

    /// 登录这一家（接入面板的"登录"）：Claude Code、Codex 打开浏览器、等你登录完；Pi 开终端，你回到 CuePad 时再问（`recheckAgents`）。
    func logIn(_ kind: AgentKind) async {
        guard kind.loginArguments != nil else {
            do { try await services.agents.openPiLogin() } catch { fail(error) }
            return
        }
        await services.agents.logIn(kind)
        await recheckAgents()
    }

    /// 重新检测这台的 Agent 并问它们能不能用（面板打开、回到 App、装完、登录完）：写进库，面板读库。
    func recheckAgents() async {
        do { try await services.macAgents.record(redetecting: true) } catch { fail(error) }
    }

    /// 接入面板的主按钮：接入勾选的几家（同设置里打开开关），`enablingCue` 时再让 Cue 在这台 Mac 上启用（`AppServices.enableCue`），
    /// 启用了就去 Cue 页，接着就能对它说。接入有一家没装上不拦着启用：Cue 能用别家。
    func setUp(connecting kinds: [AgentKind], enablingCue: Bool) async -> SetupFailures {
        var failures = SetupFailures(agents: await services.agents.install(kinds))
        guard enablingCue else { return failures }
        do {
            try await services.enableCue(on: services.hostID, moving: false)
            show(.cue)
        } catch CueEnableError.noRuntime(let why) {
            failures.cue = why
        } catch {
            failures.cue = error.localizedDescription
        }
        return failures
    }
}

/// 接入面板里一家 Agent 那一行（`Workspace.setupRows`）。
struct SetupRow: Equatable, Identifiable {
    let kind: AgentKind
    let step: SetupStep
    var id: AgentKind { kind }
}

/// 一家这一步要你做什么。
enum SetupStep: Equatable {
    /// 还在检测，或装好、登录后还没问过它能不能用
    case checking
    /// 没装（或太旧）："安装"，带上次没装成的原因
    case install(String?)
    /// 没装，装它要先有的这台没有（`AgentStatus.lacking`）：给官网
    case needs(InstallPrerequisite)
    case installing
    /// 装了没登录："登录"，带上次没登录成的原因
    case logIn(String?)
    /// 在等你在浏览器里登录完："重新登录"
    case loggingIn
    /// 勾上接入（同设置里打开开关）
    case connect
    /// 别的原因（问不出模型……），只写出来
    case problem(String)

    /// 平时也列出来的：要你点的（勾上接入、登录）
    var isActionable: Bool {
        switch self {
        case .connect, .logIn, .loggingIn, .installing: true
        default: false
        }
    }
}

/// 接入面板的主按钮没做成的：哪家没装上与原因、Cue 为什么没启用（这台 Mac 上的 Agent 都在这里，只写各家为什么）。
struct SetupFailures: Equatable {
    var agents: [AgentKind: String] = [:]
    var cue: String?

    var isEmpty: Bool { agents.isEmpty && cue == nil }
}

/// 接入 Agent 并启用 Cue，一处做完：首次打开出现一次（`Workspace.offerSetup`），Cue 页的启用卡、会话页的"接入"也打开它；之后在设置里逐个开关。
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
    /// 检测完了，没有要做的。
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
        .animation(Motion.quick, value: checked)
        .onAppear { withAnimation(reduceMotion ? Motion.quick : Motion.snappy) { shown = true } }
        .observing(services.store, into: $here, onError: workspace.fail) { [host = services.hostID] in try $0.macAgents(on: host) }
        .task {
            await workspace.recheckAgents()
            checked = true
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) { await workspace.recheckAgents() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(Mascot.hello.rawValue).resizable().scaledToFit().frame(width: 64, height: 64)
                .scaleEffect(shown || reduceMotion ? 1 : 0.9)
                .opacity(shown ? 1 : 0)
                .accessibilityHidden(true)
            Text(setupCue == .none ? "接入 Agent" : "接入 Agent，启用 \(cueName)").font(Typography.heading).foregroundStyle(palette.ink)
        }
    }

    @ViewBuilder private var content: some View {
        if !checked {
            note { Spinner(.small); Text("正在检测 Agent…") }
        } else {
            if setupCue == .needsAgent {
                Text("先\(logsInFirst ? "登录" : "装")一个能当 \(cueName) 的 Agent").font(Typography.secondary).foregroundStyle(palette.ink2)
                    .padding(.horizontal, 4)
            }
            if !rows.isEmpty || cueRowShown {
                group {
                    ForEach(rows) { row($0) }
                    if cueRowShown { cueRow }
                }
            }
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
            case .install:
                action("安装", kind) { await workspace.installAgent(kind) }
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
                ?? AgentLine.of(kind, agents.status(kind), writable: agents.isWritable(kind))
            return (tone, line, working && chosen.contains(kind))
        case .checking: return (.calm, "检查中…", true)
        case .install(let failure?), .logIn(let failure?): return (.failure, Dotted(failure), false)
        case .install: return (.calm, Dotted(kind == .claudeCode ? "推荐" : nil, "运行官方安装脚本"), false)
        case .needs(let prerequisite):
            return (.notice, Dotted("需要 \(prerequisite.name) \(prerequisite.minimum.major).\(prerequisite.minimum.minor) 以上"), false)
        case .installing: return (.calm, "安装中，可能要几分钟", true)
        case .logIn: return (.calm, kind.loginArguments == nil ? "在 \(kind.name) 里输入 /login" : "在浏览器里登录", false)
        case .loggingIn: return (.calm, "在浏览器里登录完回到这里", true)
        case .problem(let why): return (.notice, Dotted(why), false)
        }
    }

    private func action(_ title: String, _ kind: AgentKind, _ run: @escaping () async -> Void) -> some View {
        Button(title) { Task { await run() } }
            .buttonStyle(ControlButtonStyle(kind: .secondary))
            .accessibilityLabel("\(title) \(kind.name)")
    }

    /// 启用 Cue 那一行：默认项目还没有文件夹时写它第一次开工时建在哪（`Workspaces`）。没启用成的写原因。
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
        let workspaces = services.workspaces
        return "开工时建好 \(workspaces.shown(workspaces.directory(for: home.name).path(percentEncoded: false)))"
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
