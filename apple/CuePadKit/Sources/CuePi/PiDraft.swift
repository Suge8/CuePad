#if os(macOS)
import Foundation

/// 一个在线会话此刻正在说的这条回答：主会话自己的正文到目前为止的全文（不含思考、工具参数与子代理），只在桥的内存里，
/// 不入库、不同步、不进 `PiBridge.changes()`。说完的那条仍以从会话文件读出、落库的对话为准，界面在它落库后换下草稿。
/// 各家接入维护（`PiBridge.setDraft`）：这条开始出字时设上、随增量更新；它转成工具调用、这一轮被停下或出错、下一轮开始时清掉；
/// 正常说完的留着，由界面在对话里出现它之后换下。
public struct PiDraft: Equatable, Sendable {
    public var text: String
    /// 这条回答的起点：晚于对话里上一条回答的时刻，不晚于这条落库后在对话里的时刻，界面据此认出它已落库（`landed`）。
    /// 对话里回答的时刻是写完那一刻的（Pi、Claude Code、Codex）取开始出字；是消息建立那一刻的（OpenCode）取那一刻
    public var since: Date

    public init(text: String, since: Date) {
        self.text = text
        self.since = since
    }
}
#endif
