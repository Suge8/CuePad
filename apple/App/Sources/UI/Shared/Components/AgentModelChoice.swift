import CueStore
import SwiftUI

extension ConfigControls {
    /// 选了做什么由调用方给；换了家时模型回到那家的默认也由调用方写（新会话记在表单里，Cue 记在设置里）。
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
