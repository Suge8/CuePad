#if os(macOS)
import CueAgent
import CueStore
import Foundation

struct CueRound: Identifiable {
    let id: Int
    let wake: CueWake
    let startedAt: Date
    var sent: [String]
    var calls: [CueToolCall] = []
    var finishedAt: Date?
    var failure: String?
    var context: Int?
    var row: UUID?

    static let resultLimit = 20_000

    var running: CueToolCall? { calls.last { $0.finishedAt == nil } }

    var process: ChatMessage.Tools? {
        let items = calls.compactMap(\.item)
        guard !items.isEmpty else { return nil }
        var tools = ChatMessage.Tools()
        for item in items { tools.record(item) }
        return tools
    }

    mutating func finish(_ id: String, result: String, failed: Bool, item: ChatMessage.Tools.Item) {
        guard let index = calls.lastIndex(where: { $0.id == id && $0.finishedAt == nil }) else { return }
        calls[index].finishedAt = .now
        calls[index].result = result.count <= Self.resultLimit ? result : String(result.prefix(Self.resultLimit)) + "\n…"
        calls[index].failed = failed
        calls[index].item = item
    }
}

struct CueToolCall: Identifiable {
    let id: String
    let name: String
    let arguments: String
    let named: CueActivity.Named
    let step: CueActivity.Touch?
    let detail: String?
    let startedAt: Date
    var requests: [UUID] = []
    var finishedAt: Date?
    var result: String?
    var failed = false
    var item: ChatMessage.Tools.Item?
}
#endif
