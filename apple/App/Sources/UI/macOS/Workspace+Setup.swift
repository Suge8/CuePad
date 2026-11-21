#if os(macOS)
import CueBridge
import CueStore

extension Workspace {
    func offerSetup() {
        guard !services.settings.setupOffered, cue.hostID == nil else { return }
        services.settings.setupOffered = true
        showsSetup = true
    }

    enum SetupCue: Equatable {
        case none
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
        if services.connectableAgents.contains(kind) { return .connect }
        switch problem {
        case nil, .notInstalled?: return failure.map(SetupStep.problem) ?? (here.kinds.contains(kind) ? nil : .checking)
        case let reason?: return .problem(reason.description)
        }
    }

    func installAgent(_ kind: AgentKind) async {
        do { try await services.installAgent(kind) } catch { fail(error) }
    }

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

    func setUp(connecting kinds: [AgentKind], enablingCue: Bool) async -> SetupFailures {
        services.connectAgents(kinds)
        var failures = SetupFailures()
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
    var cue: String?

    var isEmpty: Bool { cue == nil }
}
#endif
