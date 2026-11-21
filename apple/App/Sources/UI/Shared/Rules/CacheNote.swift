import CueStore
import Foundation

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
    nonisolated func minutesLeft(at now: Date) -> Int? {
        guard let seconds = warmUntil?.timeIntervalSince(now), seconds > 0 else { return nil }
        return Int((seconds / 60).rounded(.up))
    }

    nonisolated func nextTick(after now: Date) -> Date? {
        guard let warmUntil, let left = minutesLeft(at: now) else { return nil }
        return warmUntil.addingTimeInterval(-Double(left - 1) * 60)
    }
}
