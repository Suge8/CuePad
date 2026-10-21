#if os(macOS)
import CuePi
import CueStore

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
#endif
