#if DEBUG
import Foundation

/// `-CuePadCueNow islandLarge|islandWaiting|islandUnknown|islandZero|islandLong`：压测大数、旧快照与长内容，不改共用样例。
enum CueActivitySamples {
    static let tour = [CueNowSamples.four, CueNowSamples.fourWorking, CueNowSamples.delegating,
                       CueNowSamples.asks, CueNowSamples.done, CueNowSamples.hearing, CueNowSamples.awayBusy]

    static func named(_ name: String) -> CueNow? {
        var now = CueNowSamples.fourWorking
        switch name {
        case "islandLarge": now.agentCount = 12_345
        case "islandWaiting":
            now = CueNowSamples.busy
            now.tally.asks = 999
            now.tally.reply = 1
            now.agentCount = 12_345
        case "islandLong":
            now = CueNowSamples.crowded
            let title = now.first!.title
            now.first?.detail = title
            now.first?.title = String(repeating: title, count: 3)
        case "islandUnknown": now.agentCount = nil
        case "islandZero": now.agentCount = 0
        default: return nil
        }
        return now
    }
}
#endif
