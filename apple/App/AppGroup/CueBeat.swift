import Foundation

nonisolated enum CueBeat: String, Codable, Sendable, CaseIterable {
    case resting
    case hearing
    case thinking
    case delegating
    case waiting
    case done
    case failed
    case away

    enum Dot: Sendable { case moving, failed }

    var dot: Dot? {
        switch self {
        case .hearing, .thinking: .moving
        case .failed: .failed
        case .resting, .delegating, .waiting, .done, .away: nil
        }
    }

    var faded: Bool { self == .away }

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

    /// 全身的那张叫什么：Cue 页舞台画 "cue-stage-" 接它（200pt），锁屏的实时活动画 "cue-pose-" 接它（`CuePoses`，同一张缩到 140pt：
    /// 实时活动里比那一块还大的图系统可能不画）。
    var pose: String {
        switch self {
        case .resting, .hearing: "idle"
        case .thinking, .failed: "think"
        case .delegating: "wave"
        case .waiting: "offer"
        case .done: "jump"
        case .away: "sleep"
        }
    }

    func composing(_ drafting: Bool) -> CueBeat { drafting && self == .done ? .resting : self }
}
