import Foundation

/// Cue 此刻是哪一拍：头像、小组件、灵动岛的样子只从这一个值出（资源、点、变不变淡在这里；
/// App 里会动的那几样——帧序列、换拍子的软糖——在 `CueSprite`、`JellyMove.cue`，都按它 switch）。
/// 不另存：由 Cue 此刻存着的事实推出（`CueNow.beat`，规则只在那里），App 与扩展读同一条；App 里各处的头像再经 `CueWatch.beat`（接力、正在写）。
/// 否决过：表情（`CueMood`）与"在做什么"两份各推各的再拼起来——同一时刻一处说在动、另一处说歇着，很多组合根本不会出现；
/// 拍子随快照另存一份——过时、刚做完到点收掉时要几处一起改，漏一处就不一致。
nonisolated enum CueBeat: String, Codable, Sendable, CaseIterable {
    /// 歇着：手上没事，或推进中的都歇着。
    case resting
    /// 你的话在路上（在听）。
    case hearing
    /// 在一轮里（在想）。
    case thinking
    /// 自己歇下、等派出去的子代理交回（手搭凉棚望着）。Cue 自己没在动：没有点。
    case delegating
    /// 有要你管的：拍板或待回复（举着卡片）。
    case waiting
    /// 它刚报了一件做完的。
    case done
    /// 起不来：要你处理，醒着、为难的脸，不变淡。
    case failed
    /// 不在：没启用、它运行的 Mac 没开、还没和 iCloud 对过。睡脸、整只变淡，不用管。
    case away

    /// 右下那颗点：在动是靛青，起不来是胭脂，其余没有。
    enum Dot: Sendable { case moving, failed }

    var dot: Dot? {
        switch self {
        case .hearing, .thinking: .moving
        case .failed: .failed
        case .resting, .delegating, .waiting, .done, .away: nil
        }
    }

    /// 不在的整只变淡（`CueFaceMarks.awayOpacity`）；起不来不淡——要你处理的不能读成"不用管"。
    var faded: Bool { self == .away }

    /// 静止的那张（`CueFaces` 里的 mascot-cue-*）：小组件、灵动岛、不放循环动效时与帧序列的底图。
    var still: String {
        switch self {
        case .resting, .hearing: "mascot-cue-listening"
        case .thinking: "mascot-cue-thinking"
        case .delegating: "mascot-cue-visor"
        case .waiting: "mascot-cue-waiting"
        case .done: "mascot-cue-done"
        case .failed: "mascot-cue-failed"
        case .away: "mascot-cue-sleeping"
        }
    }

    /// 你正在写时：刚做完的让给"在听"（歇着那张），别的照旧。
    func composing(_ drafting: Bool) -> CueBeat { drafting && self == .done ? .resting : self }
}
