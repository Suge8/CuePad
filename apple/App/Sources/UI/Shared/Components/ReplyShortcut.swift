import Foundation

/// 会话回复框的键盘快捷键，唯一定义：Mac 主菜单的"回复"一组（快捷键在那里看）、iPad 外接键盘的按键命令都读它。
/// 由回复框的文字区接（`ComposerField`：Mac 是主菜单项经响应链找到它，iPad 是它的按键命令），所以只在回复框聚焦时可用。
enum ReplyShortcut: Int, CaseIterable {
    /// 点按发送钮：Agent 在跑时是等它做完再说（`MacDelivery.button`）
    case send
    /// 长按发送钮：Agent 在跑时是马上说
    case sendHeld
    case model
    case thinking
    /// 空回复框里按 ↑：调回你在这个会话里说过的上一句（`PiChat.lastSaid`）；方向键不进菜单
    case recall

    var title: String {
        switch self {
        case .send: "发送"
        case .sendHeld: "马上说"
        case .model: "选择模型…"
        case .thinking: "选择思考强度…"
        case .recall: "调回上一句"
        }
    }

    /// 主键（都带 ⌘，`shift` 时再加 ⇧）："\r" 是回车；`recall` 是不带修饰的 ↑，由文字区自己的按键处理接（见 `Composer`），不进菜单。
    var input: String {
        switch self {
        case .send, .sendHeld: "\r"
        case .model: "m"
        case .thinking: "e"
        case .recall: ""
        }
    }

    var shift: Bool { self == .sendHeld || self == .model || self == .thinking }

    /// 写给人看的组合键："⌘⇧M"。
    var symbols: String {
        switch self {
        case .recall: "↑"
        case .send, .sendHeld, .model, .thinking: "⌘" + (shift ? "⇧" : "") + (input == "\r" ? "↩" : input.uppercased())
        }
    }

    /// 进主菜单的几项（↑ 只是文字区的按键）。
    static var menu: [ReplyShortcut] { allCases.filter { $0 != .recall } }
}
