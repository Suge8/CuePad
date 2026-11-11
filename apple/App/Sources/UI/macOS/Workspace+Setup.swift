#if os(macOS)
import CueBridge
import CueStore

extension Workspace {
    /// Cue 从没在哪台 Mac 上设过（`CueProfile.hostID`，停用后仍留着）就弹，只这一次，不等检测与同步。已接入 Agent、只差 Cue 的老用户也弹这一次，停用过 Cue 的不再打扰。"出现过"记在 `AppSettings.setupOffered`：看过不接的人身上没有别的事实留下来。
    func offerSetup() {
        guard !services.settings.setupOffered, cue.hostID == nil else { return }
        services.settings.setupOffered = true
        showsSetup = true
    }

    /// 什么时候有、能不能勾只在这里定。检测完、问过这台的 Agent 之后读，之前面板只写检测中。
    enum SetupCue: Equatable {
        case none
        /// Cue 也许已在别的 Mac 上设过（换新 Mac 时库还没和 iCloud 对过一遍），先不提议在这台启用，免得把它从那台抢过来。
        case waiting(String)
        case needsAgent
        case enable
    }

    func setupCue(here: MacAgents) -> SetupCue {
        switch CueGate.of(services, running: cue.canHear ? cue.hostID : nil, name: cue.hostName) {
        case .runs: return .none
        case .waiting(let why): return .waiting(why)
        case .open:
            return here.kinds.isEmpty ? .needsAgent : .enable
        }
    }

    func setupRows(here: MacAgents) -> [SetupRow] {
        let needsAgent = setupCue(here: here) == .needsAgent
        return Self.rowOrder.compactMap { kind in
            setupStep(kind, here: here).map { SetupRow(kind: kind, step: $0) }
        }.filter { $0.step.isActionable || needsAgent }
    }

    private static let rowOrder: [AgentKind] = [.claudeCode, .codex, .pi, .opencode, .grok, .dsh]

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

    func installAgent(_ kind: AgentKind) async {
        do { try await services.installAgent(kind) } catch { fail(error) }
    }

    /// Pi 开终端，你回到 CuePad 时再问（`recheckAgents`）。
    func logIn(_ kind: AgentKind) async {
        guard kind.facts.loginArguments != nil else {
            do { try await services.agents.openPiLogin() } catch { fail(error) }
            return
        }
        await services.agents.logIn(kind)
        await recheckAgents()
    }

    func recheckAgents() async {
        do { try await services.macAgents.record(redetecting: true) } catch { fail(error) }
    }

    /// 接入有一家没装上不拦着启用：Cue 能用别家。
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

struct SetupRow: Equatable, Identifiable {
    let kind: AgentKind
    let step: SetupStep
    var id: AgentKind { kind }
}

enum SetupStep: Equatable {
    case checking
    case install(String?)
    case needs(InstallPrerequisite)
    case installing
    case logIn(String?)
    case loggingIn
    case connect
    case problem(String)

    var isActionable: Bool {
        switch self {
        case .connect, .logIn, .loggingIn, .installing: true
        default: false
        }
    }
}

struct SetupFailures: Equatable {
    var agents: [AgentKind: String] = [:]
    var cue: String?

    var isEmpty: Bool { agents.isEmpty && cue == nil }
}
#endif
