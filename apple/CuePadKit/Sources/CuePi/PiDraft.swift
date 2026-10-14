#if os(macOS)
import Foundation
import Observation

/// 此刻正在说的这条回答：到目前为止的正文全文（不含思考、工具参数与子代理），只在 Mac 的内存里，不入库、不同步。
/// 说完的那条仍以库里的对话为准，界面在它落库后原位换下（`landed`，在 App 里）。两处来源，规则相同：
/// - 在线会话：各家接入维护，经 `PiBridge.setDraft` 放进这个会话的格子（不进 `PiBridge.changes()`）；
/// - Cue：大脑报 `CueBrainEvent.speaking`，值班的 `CueKeeper` 只把在回答你的那一轮放进 `CueKeeper.speech`。
/// 这条开始出字时设上、随增量更新；它转成工具调用、这一轮被停下或出错、下一轮开始时清掉；正常说完的留着，由界面在对话里出现它之后换下。
public struct PiDraft: Equatable, Sendable {
    public var text: String
    /// 这条回答的起点：晚于对话里上一条回答的时刻，不晚于这条落库后在对话里的时刻，界面据此认出它已落库（`landed`）。
    /// 对话里回答的时刻是写完那一刻的（Pi、Claude Code、Codex 与 Cue 的对话）取开始出字；是消息建立那一刻的（OpenCode）取那一刻
    public var since: Date

    public init(text: String, since: Date) {
        self.text = text
        self.since = since
    }
}

/// 一条回答正在说的话怎么拼（各家协议层共用，各自只把事件映射到这几个动作）：依次说出的几段正文按段号排、换行连接（同对话里回答的写法）；
/// 说到一半的段由增量追加，说完的段换成运行时给的定稿（不发增量也照样有全文）；起点是第一次出字的时刻，或由调用方给；全是空白时没有。
/// 换一条回答（`message` 变了）、转成工具调用等就新建一个。没变也照样交出去：去重只在下游一处（`PiDraftFeed`）。
struct DraftParts {
    /// 这条回答的标识（消息、项）；不分条的为 nil
    let message: String?
    private var parts: [Int: String] = [:]
    private var since: Date?

    init(message: String? = nil, since: Date? = nil) {
        self.message = message
        self.since = since
    }

    /// 最后一段的段号
    var lastPart: Int? { parts.keys.max() }

    mutating func append(_ delta: String, to part: Int) {
        parts[part, default: ""] += delta
        since = since ?? .now
    }

    mutating func finish(_ part: Int, with text: String) {
        parts[part] = text
        since = since ?? .now
    }

    var draft: PiDraft? {
        let text = parts.sorted { $0.key < $1.key }.map(\.value).joined(separator: "\n")
        guard let since, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return PiDraft(text: text, since: since)
    }
}

/// 给界面看的正在说的话（`draft`），出字时只有读它的视图重算。来源每个增量交一次（`offer`），刷新节奏只定在这里：
/// 同一条话的增长最多每 `interval` 显示一次（落后的那次在这一拍末尾补上）；清掉与开始另一条（起点不同）立即显示，不让上一条的尾巴晚到。
@MainActor @Observable
public final class PiDraftFeed {
    public private(set) var draft: PiDraft?
    /// `draft != nil`，只在有无变化时通知
    public private(set) var speaking = false
    /// 最近交来、还没显示的与等着显示它的那一拍
    @ObservationIgnored private var offered: PiDraft?
    @ObservationIgnored private var shownAt: ContinuousClock.Instant?
    @ObservationIgnored private var flush: Task<Void, Never>?

    /// 逐字的增量（每秒几十个）合成每秒十次：读它的视图（Markdown 重排）不随每个增量重算
    static let interval: Duration = .milliseconds(100)

    public init() {}

    public func offer(_ next: PiDraft?) {
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
