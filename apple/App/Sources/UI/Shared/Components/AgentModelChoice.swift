import CueStore
import SwiftUI

extension PiConfigControls where Trailing == EmptyView {
    /// 用哪个 Agent、哪个模型与多大思考强度：新会话（手机的输入框、Mac 的表单）与 Cue（Mac 的 Cue 页输入框、手机的 Cue 面板、两端的 Cue 设置）
    /// 都是这一排，与会话页回复框同一个样子，最左多一枚 Agent 胶囊（`PiAgentCapsule`）。可选什么、当前是什么只在 `AgentModelChoice`；选了做什么由调用方给，
    /// 换了家时模型回到那家的默认也由调用方写（新会话记在表单里，Cue 记在设置里）。
    init(
        choice: AgentModelChoice, opening: Binding<PiConfigPick?> = .constant(nil), chooseAgent: @escaping (AgentKind) -> Void,
        chooseModel: @escaping (PiModelKey?) -> Void, chooseThinking: @escaping (PiThinkingLevel) -> Void, chooseFast: @escaping (Bool) -> Void = { _ in }
    ) {
        self.init(
            agent: choice.agent.map { PiAgentPick(kinds: choice.agents.map(\.kind), current: $0, choose: chooseAgent) },
            models: choice.menu(choose: chooseModel), shown: PiConfigShown(model: choice.current, thinking: choice.shownThinking, fast: choice.fast, pending: false),
            unnamed: "默认模型", levels: choice.levels, opening: opening, chooseThinking: chooseThinking, chooseFast: chooseFast)
    }
}

/// 一台 Mac 上选 Agent 与模型的规则（新会话与 Cue 同一份）：
/// - 能选的几家是那台 Mac 上能用的（`MacAgents`，调用方再按自己的条件筛，如 Cue 只列有模型可选的）；当前那家不在里面时照样写它（胶囊写它的名字、菜单里不打勾）。
/// - 模型只列当前那家在那台上能选的，按提供方分组（同会话页）；不指定时用的那项标着默认，选它写回 nil：跟着这家的默认走，它换了默认也跟着换。
///   指定了却不在清单里（清单变了）照指定的 id 显示。
/// - 思考强度只列当前模型上报的档；模型不在清单里时不出控件。显示的当前档同样夹到这一集合里。没指定是“默认”。
nonisolated struct AgentModelChoice: Equatable, Sendable {
    let agents: [MacAgent]
    /// 当前那家；一家都没有为 nil（不出 Agent 胶囊）。
    let agent: AgentKind?
    /// 指定的模型；nil 是这家的默认。
    let model: PiModelKey?
    let thinking: PiThinkingLevel?
    var fast: Bool? = nil

    private var brain: MacAgent? { agent.flatMap { kind in agents.first { $0.kind == kind } } }

    /// 胶囊上写的模型：指定的那项，没指定是这家的默认。
    var current: PiModelOption? {
        guard let model else { return brain?.defaultModel }
        return brain?.models.first { $0.key == model } ?? PiModelOption(key: model, name: "", thinkingLevels: [])
    }

    var levels: [PiThinkingLevel] {
        current.flatMap { current in brain?.models.first { $0.key == current.key }?.thinkingLevels } ?? []
    }

    var shownThinking: PiThinkingLevel? { thinking.map { $0.clamped(to: levels) } }

    /// 选了不指定时用的那项写回 nil：跟着这家的默认走。
    @MainActor func menu(choose: @escaping (PiModelKey?) -> Void) -> PiModelMenu {
        PiModelMenu(models: brain?.models ?? [], defaultModel: brain?.model, current: current?.key) { option in
            choose(option.key == brain?.model ? nil : option.key)
        }
    }
}
