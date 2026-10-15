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
        let menu = menu ?? CueBrainMenu(profile: CueProfile(), lists: [:])
        PiConfigControls(
            groups: groups(menu), shown: PiConfigShown(model: menu.model, thinking: menu.thinking, pending: false),
            unnamed: menu.runtime.map { "\($0.name) 默认" } ?? "默认", levels: menu.levels, opening: opening
        ) { level in
            update { $0.effort = .known(level) }
        }
        .observing(services.store, into: $menu, onError: workspace.fail) { try CueBrainMenu.read(from: $0) }
    }

    /// 一家一组；选了别家的模型就是换 Agent。
    private func groups(_ menu: CueBrainMenu) -> [PiModelGroup] {
        CueProfile.runtimes.map { agent in
            let mine = menu.runtime == agent
            let fallback = PiModelGroup.Item(id: "default", model: nil, checked: mine && menu.profile.model == nil) {
                update {
                    $0.runtime = .known(agent)
                    $0.model = nil
                }
            }
            let models = (menu.lists[agent] ?? []).map { model in
                let ref = agent.modelRef(model.key)
                return PiModelGroup.Item(id: ref, model: model, checked: mine && menu.model?.key == model.key) {
                    update {
                        $0.runtime = .known(agent)
                        $0.model = ref
                    }
                }
            }
            return PiModelGroup(id: agent.rawValue, title: agent.name, agent: agent, items: models.isEmpty ? [fallback] : models)
        }
    }

    private func update(_ edit: @escaping @Sendable (inout CueProfile) -> Void) {
        workspace.attempt { try await services.updateCue(edit) }
    }
}

/// Cue 的模型菜单读的：设置（`CueProfile`）与 Cue 住的那台 Mac 上各家可选的模型。
/// - 按能当大脑的几家分组（`CueProfile.runtimes`）：组里是这家在那台 Mac 上最近一个报了模型清单的会话的清单（`CueStore.modelLists`）；
///   这家在那台上没有清单（没跑过、或还没选住在哪台）时只有一项"默认"，用这家自己的默认模型。
/// - 当前模型：清单里有就是那一项；不在清单里（清单变了）照设置的写法读出、只显示它的 id；用默认为 nil。
/// - 思考强度的档跟着当前模型：在清单里就是它支持的档；不在清单里（默认或清单变了）不知道它支持什么，取这家清单里各模型支持的档的并集，
///   清单也没有时是全部档——大脑起来时各家都按模型夹取（`PiThinkingLevel.clamped`），选了也不会出错；显示的当前档同样按这一集合夹取。
nonisolated struct CueBrainMenu: Equatable, Sendable {
    var profile: CueProfile
    var lists: [AgentKind: [PiModelOption]]

    static func read(from store: isolated CueStore) throws -> CueBrainMenu {
        let profile = try store.cueProfile() ?? CueProfile()
        return CueBrainMenu(profile: profile, lists: try profile.hostID.map { try store.modelLists(on: $0) } ?? [:])
    }

    /// 用哪家；更新的版本写的、不认识的为 nil（菜单里哪项都不打勾）。
    var runtime: AgentKind? { profile.runtime.known }

    private var list: [PiModelOption] { runtime.flatMap { lists[$0] } ?? [] }

    var model: PiModelOption? {
        guard let runtime, let ref = profile.model else { return nil }
        return listed ?? PiModelOption(key: runtime.modelKey(ref) ?? PiModelKey(provider: "", id: ref), name: "", thinkingLevels: [])
    }

    /// 设置里的模型在清单里的那一项：按这家的写法比（`AgentKind.modelRef`，选的时候就是这样写进去的）。
    private var listed: PiModelOption? {
        guard let runtime, let ref = profile.model else { return nil }
        return list.first { runtime.modelRef($0.key) == ref }
    }

    var levels: [PiThinkingLevel] {
        if let listed { return listed.thinkingLevels }
        let supported = Set(list.flatMap(\.thinkingLevels))
        return supported.isEmpty ? PiThinkingLevel.allCases : PiThinkingLevel.allCases.filter(supported.contains)
    }

    var thinking: PiThinkingLevel? { profile.effort?.known.map { $0.clamped(to: levels) } }
}
