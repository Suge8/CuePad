#if os(macOS)
import Foundation
import Observation

/// 此刻正在说的这条回答（不含思考、工具参数与子代理），只在 Mac 的内存里，不入库、不同步。说完的那条仍以库里的对话为准，界面在它落库后原位换下（`landed`，在 App 里）。两处来源，规则相同：
/// - 在线会话：各家接入维护，经 `Bridge.setDraft` 放进这个会话的格子（不进 `Bridge.changes()`）；
/// - Cue：大脑报 `TurnEvent.speaking`，值班的 `CueKeeper` 只把在回答你的那一轮放进 `CueKeeper.speech`。
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

    /// 会话页与 Cue 页同一条规则。`newestReply` 是对话里最新那条回答的时刻与它的 `ChatMessage.id`（对话不是从会话文件读出来的，
    /// 如 Cue 页，给 nil）：两边都有身份时按身份认；否则按时刻认，不按文字认：两轮说了一样的话也认得开。
    /// 按毫秒比：两边是同一个毫秒精度的时钟，一边从毫秒数、一边从会话文件的时间文字换算，
    /// 同一毫秒换出的 `Date` 会差一个舍入误差（实测差 1e-7 秒），直接比时常认不出同一刻。
    public func landed(newestReply at: Date?, record newest: UUID?) -> Bool {
        guard let at else { return false }
        if let record, let newest { return record == newest }
        return Self.milliseconds(at) >= Self.milliseconds(since)
    }

    private static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}

/// 各家协议层共用，各自只把事件映射到这几个动作。依次说出的几段正文按段号排、换行连接（同对话里回答的写法）；定稿带着运行时记下的时刻时改用其中最早的（`LiveDraft.since`）。
/// 没变也照样交出去：去重只在下游一处（`LiveDraftFeed`）。
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

    /// `at` 是运行时把这段记进会话文件的时刻（给得出的才给）。
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

/// 来源每个增量交一次（`offer`），刷新节奏只定在这里：清掉与开始另一条（起点不同）立即显示，不让上一条的尾巴晚到。
@MainActor @Observable
public final class LiveDraftFeed {
    public private(set) var draft: LiveDraft?
    public private(set) var speaking = false
    @ObservationIgnored private var offered: LiveDraft?
    @ObservationIgnored private var shownAt: ContinuousClock.Instant?
    @ObservationIgnored private var flush: Task<Void, Never>?

    /// 逐字的增量合成 `interval` 一次：读它的视图（Markdown 重排）不随每个增量重算
    static let interval: Duration = .milliseconds(100)

    public init() {}

    public func offer(_ next: LiveDraft?) {
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

    private func show(at now: ContinuousClock.Instant) {
        flush?.cancel()
        flush = nil
        shownAt = now
        if draft != offered { draft = offered }
        if speaking != (offered != nil) { speaking = offered != nil }
    }
}
#endif
