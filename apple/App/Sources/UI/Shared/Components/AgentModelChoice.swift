import CueStore
import SwiftUI

extension ConfigControls {
    init(
        choice: AgentModelChoice, opening: Binding<ConfigPick?> = .constant(nil), chooseAgent: @escaping (AgentKind) -> Void,
        chooseModel: @escaping (ModelKey?) -> Void, chooseThinking: @escaping (ThinkingLevel) -> Void, chooseFast: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.init(
            agent: choice.agent.map { AgentPick(kinds: choice.agents.map(\.kind), current: $0, choose: chooseAgent) },
            models: choice.menu(choose: chooseModel), shown: ConfigShown(model: choice.current, thinking: choice.shownThinking, fast: choice.fast, pending: false),
            unnamed: "默认模型", levels: choice.levels, opening: opening, chooseThinking: chooseThinking, chooseFast: chooseFast, trailing: trailing)
    }
}

nonisolated struct AgentModelChoice: Equatable, Sendable {
    let agents: [MacAgent]
    let agent: AgentKind?
    let model: ModelKey?
    let thinking: ThinkingLevel?
    var fast: Bool = false

    private var brain: MacAgent? { agent.flatMap { kind in agents.first { $0.kind == kind } } }

    var current: ModelOption? {
        guard let model else { return brain?.defaultModel }
        return brain?.models.first { $0.key == model } ?? ModelOption(key: model, name: "", thinkingLevels: [])
    }

    var levels: [ThinkingLevel] {
        current.flatMap { current in brain?.models.first { $0.key == current.key }?.thinkingLevels } ?? []
    }

    var shownThinking: ThinkingLevel? { thinking.map { $0.clamped(to: levels) } }
    var launchFast: Bool { fast && current?.supportsFast == true }

    @MainActor func menu(choose: @escaping (ModelKey?) -> Void) -> ModelMenu {
        ModelMenu(models: brain?.models ?? [], defaultModel: brain?.model, current: current?.key) { option in
            choose(option.key == brain?.model ? nil : option.key)
        }
    }
}

struct LaunchControls: View {
    let mac: MacAgents
    let project: UUID?
    @Environment(AppServices.self) private var services

    var body: some View {
        let settings = services.settings, project = project
        if let choice = settings.launchChoice(on: mac, in: project), let agent = choice.agent {
            ConfigControls(choice: choice) { kind in
                settings.setLaunchPreference(for: project) { $0.agent = kind }
            } chooseModel: { model in
                settings.setLaunchPreference(for: project) { $0.models[agent] = model }
            } chooseThinking: { level in
                settings.setLaunchPreference(for: project) { $0.thinking = level }
            } chooseFast: { fast in
                settings.setLaunchPreference(for: project) { $0.fast = fast }
            }
        }
    }
}

extension View {
    func observingLaunchAgents(
        id: some Equatable, into agents: Binding<MacAgents?>, onError: @escaping (any Error) -> Void,
        host: @escaping @Sendable (isolated CueStore) throws -> String?
    ) -> some View {
        modifier(LaunchAgentsReading(id: id, agents: agents, onError: onError, host: host))
    }
}

private struct LaunchAgentsReading<ID: Equatable>: ViewModifier {
    let id: ID
    @Binding var agents: MacAgents?
    let onError: (any Error) -> Void
    let host: @Sendable (isolated CueStore) throws -> String?
    @Environment(AppServices.self) private var services

    func body(content: Content) -> some View {
        content.observing(services.store, id: id, into: Binding(get: { agents.map(Optional.some) }, set: { agents = $0 ?? nil }), onError: onError) {
            [host] store in
            try host(store).map { try store.macAgents(on: $0) }
        }
    }
}
