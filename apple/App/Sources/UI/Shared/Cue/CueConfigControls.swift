import CueStore
import SwiftUI

/// Cue 页输入框里的模型与思考强度（与会话页回复框同一组件 `PiConfigControls`）：选的是 Cue 的大脑。
/// 值只在同步的 `CueProfile`（`runtime`、`model`、`effort`），选了经 `AppServices.updateCue` 写入并上传；Cue 住的那台 Mac 读到就按它值班。
/// 规则见 `CueBrainMenu`。
struct CueConfigControls: View {
    var opening: Binding<PiConfigPick?> = .constant(nil)
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var menu: CueBrainMenu?

    var body: some View {
        let menu = menu ?? CueBrainMenu(profile: CueProfile(), agents: MacAgents(hostID: "", agents: [], modifiedAt: .distantPast))
        PiConfigControls(
            groups: groups(menu), shown: PiConfigShown(model: menu.model, thinking: menu.thinking, pending: false),
            unnamed: menu.runtime?.name ?? "模型", levels: menu.levels, opening: opening
        ) { level in
            update { $0.effort = .known(level) }
        }
        .observing(services.store, into: $menu, onError: workspace.fail) { try CueBrainMenu.read(from: $0) }
    }

    /// 一家一组；选了别家的模型就是换 Agent。选标着默认的那项写回 nil：跟着这家的默认走，它换了默认也跟着换。
    private func groups(_ menu: CueBrainMenu) -> [PiModelGroup] {
        menu.brains.map { brain in
            let agent = brain.kind
            let items = brain.models.map { model in
                let ref = agent.modelRef(model.key)
                let isDefault = model.key == brain.model
                return PiModelGroup.Item(id: ref, model: model, isDefault: isDefault, checked: menu.runtime == agent && menu.model?.key == model.key) {
                    update {
                        $0.runtime = .known(agent)
                        $0.model = isDefault ? nil : ref
                    }
                }
            }
            return PiModelGroup(id: agent.rawValue, title: agent.name, agent: agent, items: items)
        }
    }

    private func update(_ edit: @escaping @Sendable (inout CueProfile) -> Void) {
        workspace.attempt { try await services.updateCue(edit) }
    }
}

/// Cue 的模型菜单读的：设置（`CueProfile`）与 Cue 住的那台 Mac 上能用的 Agent（`MacAgents`，各端只读它）。
/// - 按能当大脑、那台上又能用的几家分组（`CueProfile.runtimes` 里那台有的），组里是这家在那台上能选的模型，不指定时用的那项标着默认；
///   还没选住在哪台、那台还没报过时一组都没有。
/// - 当前模型：设置里没指定就是这家的默认模型（那台报的具体模型）；指定了且在清单里是那一项，不在清单里（清单变了）照设置的写法读出、只显示它的 id；
///   这家在那台上不能用、又没指定时为 nil（胶囊写这家的名字）。
/// - 思考强度的档跟着当前模型：在清单里就是它支持的档；不知道它支持什么时（不在清单里），取这家清单里各模型支持的档的并集，
///   清单也没有时是全部档——大脑起来时各家都按模型夹取（`PiThinkingLevel.clamped`），选了也不会出错；显示的当前档同样按这一集合夹取。
nonisolated struct CueBrainMenu: Equatable, Sendable {
    var profile: CueProfile
    /// Cue 住的那台上的 Agent；还没选住哪台时一家都没有。
    var agents: MacAgents

    static func read(from store: isolated CueStore) throws -> CueBrainMenu {
        let profile = try store.cueProfile() ?? CueProfile()
        let host = profile.hostID ?? ""
        return CueBrainMenu(profile: profile, agents: try store.macAgents(on: host))
    }

    /// 用哪家；更新的版本写的、不认识的为 nil（菜单里哪项都不打勾）。
    var runtime: AgentKind? { profile.runtime.known }

    /// 菜单里的几家：能当大脑、那台上能用、有模型可选。
    var brains: [MacAgent] {
        CueProfile.runtimes.compactMap(agents.agent).filter { !$0.models.isEmpty }
    }

    private var brain: MacAgent? { runtime.flatMap(agents.agent) }

    var model: PiModelOption? {
        guard let runtime else { return nil }
        guard let ref = profile.model else { return brain?.defaultModel }
        return brain?.models.first { runtime.modelRef($0.key) == ref }
            ?? PiModelOption(key: runtime.modelKey(ref) ?? PiModelKey(provider: "", id: ref), name: "", thinkingLevels: [])
    }

    /// 当前模型在清单里的那一项（知道它支持哪些档）。
    private var listed: PiModelOption? { model.flatMap { model in brain?.models.first { $0.key == model.key } } }

    var levels: [PiThinkingLevel] {
        if let listed { return listed.thinkingLevels }
        let supported = Set((brain?.models ?? []).flatMap(\.thinkingLevels))
        return supported.isEmpty ? PiThinkingLevel.allCases : PiThinkingLevel.allCases.filter(supported.contains)
    }

    var thinking: PiThinkingLevel? { profile.effort?.known.map { $0.clamped(to: levels) } }
}
