import CueStore
import SwiftUI

/// Cue 用哪个 Agent、模型与思考强度（`PiConfigControls.init(choice:)`，与新会话同一排）：选的是 Cue 的大脑。
/// Mac 在 Cue 页输入框的工具排与设置里，手机在 Cue 面板里（`CueNowPanel`，居中）与设置里。
/// 值只在同步的 `CueProfile`（`runtime`、`model`、`effort`），选了经 `AppServices.updateCue` 写入并上传；Cue 运行的那台 Mac 读到就按它值班。
/// 能选的是那台 Mac 上能用、又能当大脑（`CueProfile.runtimes`）、有模型可选的几家；还没选在哪台运行、那台还没报过时一家都没有。
/// 读不出、写不成的原因交给 `fail`（Cue 页与面板是窗口的提示，设置里就地写在那一节）：Mac 的设置窗口没有 `Workspace`。
/// 可选什么、当前是什么由放它的那一处订阅好交进来（`observingCueBrain`）：手机的面板开时才建这一排，名牌一直订阅着，长出的第一帧就是真的。
struct CueConfigControls: View {
    let choice: AgentModelChoice?
    var opening: Binding<PiConfigPick?> = .constant(nil)
    let fail: (any Error) -> Void
    var alignment = Alignment.leading
    @Environment(AppServices.self) private var services

    var body: some View {
        let choice = choice ?? AgentModelChoice(agents: [], agent: nil, model: nil, thinking: nil)
        PiConfigControls(choice: choice, opening: opening) { agent in
            update {
                $0.runtime = .known(agent)
                $0.model = nil
            }
        } chooseModel: { key in
            guard let agent = choice.agent else { return }
            update { $0.model = key.map(agent.modelRef) }
        } chooseThinking: { level in
            update { $0.effort = .known(level) }
        }
        .aligned(alignment)
    }

    private func update(_ edit: @escaping @Sendable (inout CueProfile) -> Void) {
        Task {
            do { try await services.updateCue(edit) } catch { fail(error) }
        }
    }

    /// 设置与 Cue 运行的那台 Mac 上能用的 Agent（各端只读它）。设置里的模型按这家的写法（`AgentKind.modelRef`）读回；读不出提供方时只留 id。
    static func read(from store: isolated CueStore) throws -> AgentModelChoice {
        let profile = try store.cueProfile() ?? CueProfile()
        let agents = try store.macAgents(on: profile.hostID ?? "")
        let runtime = profile.runtime.known
        return AgentModelChoice(
            agents: CueProfile.runtimes.compactMap(agents.agent).filter { !$0.models.isEmpty },
            agent: runtime,
            model: profile.model.flatMap { ref in runtime.map { $0.modelKey(ref) ?? PiModelKey(provider: "", id: ref) } },
            thinking: profile.effort?.known)
    }
}

extension View {
    /// 订阅 Cue 的大脑那一排要的（`CueConfigControls.read`：设置与那台 Mac 的 Agent），写进 `choice`。
    func observingCueBrain(into choice: Binding<AgentModelChoice?>, fail: @escaping (any Error) -> Void) -> some View {
        modifier(CueBrainReading(choice: choice, fail: fail))
    }
}

private struct CueBrainReading: ViewModifier {
    @Binding var choice: AgentModelChoice?
    let fail: (any Error) -> Void
    @Environment(AppServices.self) private var services

    func body(content: Content) -> some View {
        content.observing(services.store, into: $choice, onError: fail) { try CueConfigControls.read(from: $0) }
    }
}
