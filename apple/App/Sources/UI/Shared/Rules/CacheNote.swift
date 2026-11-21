import CueStore
import Foundation

/// 上下文旁写的提示缓存：还热着写还剩几分钟（这之前说下一句接着用缓存，是现在说的理由），冷了写这一句要原价重读多少。
/// 这一轮还在跑时缓存正被用着，不写；上下文小的冷了也不写，重读不值一提。
nonisolated enum CacheNote: Equatable {
    case warm(minutes: Int, estimated: Bool)
    case cold(tokens: Int, estimated: Bool)

    static let worthSaying = 20_000

    init?(_ cache: ChatMessage.Tools.Cache?, working: Bool, at now: Date) {
        guard let cache, !working, cache.warmUntil != nil else { return nil }
        let estimated = cache.estimated == true
        if let minutes = cache.minutesLeft(at: now) {
            self = .warm(minutes: minutes, estimated: estimated)
        } else if cache.context >= Self.worthSaying {
            self = .cold(tokens: cache.context, estimated: estimated)
        } else {
            return nil
        }
    }

    var line: String {
        switch self {
        case .warm(let minutes, let estimated): estimated ? String(localized: "缓存约 \(minutes) 分钟后过期") : String(localized: "缓存 \(minutes) 分钟后过期")
        case .cold(let tokens, let estimated):
            estimated ? String(localized: "缓存可能已冷，这一句可能重读约 \(CueContext.tokens(tokens))") : String(localized: "缓存已冷，这一句会重读约 \(CueContext.tokens(tokens))")
        }
    }
}

extension ChatMessage.Tools.Cache {
    /// 还剩几分钟（往上取整，至少 1）；冷了或没报保留时长为 nil。
    nonisolated func minutesLeft(at now: Date) -> Int? {
        guard let seconds = warmUntil?.timeIntervalSince(now), seconds > 0 else { return nil }
        return Int((seconds / 60).rounded(.up))
    }

    /// 剩的分钟数下一次变的时刻（`Moments`）：最后一分钟过完就是冷了的那一刻。
    nonisolated func nextTick(after now: Date) -> Date? {
        guard let warmUntil, let left = minutesLeft(at: now) else { return nil }
        return warmUntil.addingTimeInterval(-Double(left - 1) * 60)
    }
}
