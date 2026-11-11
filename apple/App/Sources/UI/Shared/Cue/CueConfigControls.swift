import CueStore
import SwiftUI

/// 值只在同步的 `CueProfile`（`runtime`、`model`、`effort`），选了经 `AppServices.updateCue` 写入并上传；Cue 运行的那台 Mac 读到就按它值班。
/// 可选什么、当前是什么由放它的那一处订阅好交进来（`observingCueBrain`）：手机的面板开时才建这一排，名牌一直订阅着，长出的第一帧就是真的。
struct CueConfigControls<Trailing: View>: View {
    let choice: AgentModelChoice?
    var opening: Binding<ConfigPick?> = .constant(nil)
    var alignment = Alignment.leading
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace

    let trailing: Trailing

    init(choice: AgentModelChoice?, opening: Binding<ConfigPick?> = .constant(nil), alignment: Alignment = .leading,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.choice = choice
        self.opening = opening
        self.alignment = alignment
        self.trailing = trailing()
    }

    var body: some View {
        let choice = choice ?? AgentModelChoice(agents: [], agent: nil, model: nil, thinking: nil)
        ConfigControls(choice: choice, opening: opening) { agent in
            update {
                $0.runtime = .known(agent)
                $0.model = nil
                $0.fast = false
            }
        } chooseModel: { key in
            guard let agent = choice.agent else { return }
            let models = choice.agents.first { $0.kind == agent }
            let selected = key.flatMap { key in models?.models.first { $0.key == key } } ?? models?.defaultModel
            update {
                $0.model = key.map(agent.modelRef)
                if selected?.supportsFast != true { $0.fast = false }
            }
        } chooseThinking: { level in
            update { $0.effort = .known(level) }
        } chooseFast: { fast in
            update { $0.fast = fast }
        } trailing: { trailing }
        .aligned(alignment)
    }

    private func update(_ edit: @escaping @Sendable (inout CueProfile) -> Void) {
        Task {
            do { try await services.updateCue(edit) } catch { workspace.fail(error) }
        }
    }

    /// 设置里的模型按这家的写法（`AgentKind.modelRef`）读回；读不出提供方时只留 id。
    static func read(from store: isolated CueStore) throws -> AgentModelChoice {
        let profile = try store.cueProfile() ?? CueProfile()
        let agents = try store.macAgents(on: profile.hostID ?? "")
        let runtime = profile.runtime.known
        return AgentModelChoice(
            agents: agents.agents.filter { !$0.models.isEmpty },
            agent: runtime,
            model: profile.model.flatMap { ref in runtime.map { $0.modelKey(ref) ?? ModelKey(provider: "", id: ref) } },
            thinking: profile.effort?.known, fast: profile.fast)
    }
}

extension View {
    func observingCueBrain(into choice: Binding<AgentModelChoice?>) -> some View {
        modifier(CueBrainReading(choice: choice))
    }
}

private struct CueBrainReading: ViewModifier {
    @Binding var choice: AgentModelChoice?
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        content.observing(services.store, into: $choice, onError: workspace.fail) { try CueConfigControls<EmptyView>.read(from: $0) }
    }
}
