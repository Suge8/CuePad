import CueStore
import SwiftUI

extension ConfigControls {
    /// 选了做什么由调用方给；换了家时模型换成哪个也由调用方写（开新会话按家记在本机，`LaunchControls`；Cue 记在设置里）。
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
    /// 指定的模型；nil 是这家的默认。
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

extension AppSettings {
    /// 在 `project` 里开新会话用哪家、哪个模型、多强的思考：上次选的，那台 Mac 上没有的回到它的默认。一家都不能用为 nil。
    func launchChoice(on mac: MacAgents, in project: UUID?) -> AgentModelChoice? {
        let last = launchPreference(for: project)
        guard let kind = mac.preferred(last.agent), let agent = mac.agents.first(where: { $0.kind == kind }) else { return nil }
        let model = last.models[kind].flatMap { key in agent.models.contains { $0.key == key } ? key : nil }
        return AgentModelChoice(agents: mac.agents, agent: kind, model: model, thinking: last.thinking, fast: last.fast)
    }
}

/// 开新会话的那一排（新会话的输入框、手机交给 Agent 的输入框、Mac 任务气泡的"开始"）：选了就记在本机，下次默认是它。
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
