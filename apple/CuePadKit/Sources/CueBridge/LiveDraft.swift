#if os(macOS)
import Foundation
import Observation

public struct LiveDraft: Equatable, Sendable {
    public var text: String
    /// 这条回答的起点：晚于对话里上一条回答的时刻，不晚于这条落库后在对话里的时刻（各家都是说完那一刻），没有 `record` 时界面据此认出它已落库（`landed`）。
    /// 一律取 Agent 自己的时钟（与会话文件同一个）：Pi 扩展里开始出字、Codex 的 `item/started` 的 `emittedAtMs`、OpenCode 的步骤开始、
    /// Claude Code 第一段定稿那一行的 `timestamp`（就是会话文件里那一行的；它先于 `message_start` 到这里，最多早几十毫秒，
    /// 定稿之前只能先用收到 `message_start` 的时刻）。不用本机收到事件的时刻：Agent 写下的时刻可能早于事件到这里，
    /// 落库了也认不出来，草稿一直挂在对话下面
    public var since: Date
    /// 这条落库后在对话里的那条（`ChatMessage.id`）：出字时就知道它在会话文件里是哪一项的家才给（Codex：`item/started` 的项 id，
    /// 会话文件里那一项的 id 与它相同）。Codex 的起点不保证不晚于落库的时刻：`emittedAtMs` 实测会比会话文件里那一行晚 1 毫秒
    public var record: UUID?

    public init(text: String, since: Date, record: UUID? = nil) {
        self.text = text
        self.since = since
        self.record = record
    }

    /// 会话页与 Cue 页同一条规则。`newestReply` 是对话里最新那条回答（或这一轮过程里最新那句中途的话，`Tools.Item` 的 `at` 与 `record`）
    /// 的时刻与它的 `ChatMessage.id`（对话不是从会话文件读出来的，如 Cue 页，给 nil）：两边都有身份时按身份认；否则按时刻认，
    /// 不按文字认：两轮说了一样的话也认得开。
    /// 按毫秒比：两边是同一个毫秒精度的时钟，一边从毫秒数、一边从会话文件的时间文字换算，
    /// 同一毫秒换出的 `Date` 会差一个舍入误差（实测差 1e-7 秒），直接比时常认不出同一刻。
    public func landed(newestReply at: Date?, record newest: UUID?) -> Bool {
        guard let at else { return false }
        if let record, let newest { return record == newest }
        return Self.milliseconds(at) >= Self.milliseconds(since)
    }

    private static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}

struct DraftParts {
    let message: String?
    private var parts: [Int: String] = [:]
    private var since: Date?
    private var stamped: Date?
    private let record: UUID?

    init(message: String? = nil, since: Date? = nil, record: UUID? = nil) {
        self.message = message
        self.since = since
        self.record = record
    }

    var lastPart: Int? { parts.keys.max() }

    mutating func append(_ delta: String, to part: Int) {
        parts[part, default: ""] += delta
        since = since ?? .now
    }

    mutating func finish(_ part: Int, with text: String, at time: Date? = nil) {
        parts[part] = text
        since = since ?? .now
        if let time { stamped = min(stamped ?? time, time) }
    }

    var draft: LiveDraft? {
        let text = parts.sorted { $0.key < $1.key }.map(\.value).joined(separator: "\n")
        guard let since = stamped ?? since, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return LiveDraft(text: text, since: since, record: record)
    }
}

@MainActor @Observable
public final class LiveDraftFeed {
    public private(set) var draft: LiveDraft?
    /// 最近说的那句，说完（Agent 转去调工具、被停下）也留着，下一句开说或这一轮停下才换：它落进对话之前界面接着摆它，不空一下
    public private(set) var latest: LiveDraft?
    public private(set) var speaking = false
    @ObservationIgnored private var offered: LiveDraft?
    @ObservationIgnored private var shownAt: ContinuousClock.Instant?
    @ObservationIgnored private var flush: Task<Void, Never>?

    static let interval: Duration = .milliseconds(100)

    public init() {}

    public func offer(_ next: LiveDraft?) {
        if next == nil, let offered, latest != offered { latest = offered }
        offered = next
        let now = ContinuousClock.now
        if next == nil || next?.since != draft?.since || shownAt.map({ now - $0 >= Self.interval }) ?? true {
            show(at: now)
            return
        }
        guard flush == nil, let shownAt else { return }
        flush = Task { [weak self] in
            guard (try? await Task.sleep(until: shownAt + Self.interval)) != nil else { return }
            self?.show(at: .now)
        }
    }

    func roundStopped() {
        if offered == nil, latest != nil { latest = nil }
    }

    private func show(at now: ContinuousClock.Instant) {
        flush?.cancel()
        flush = nil
        shownAt = now
        if draft != offered { draft = offered }
        if let offered, latest != offered { latest = offered }
        if speaking != (offered != nil) { speaking = offered != nil }
    }
}
#endif
