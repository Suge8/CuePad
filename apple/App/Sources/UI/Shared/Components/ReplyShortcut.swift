import Foundation

/// 唯一定义：Mac 主菜单的"回复"一组、iPad 外接键盘的按键命令都读它。
/// 由回复框的文字区接（`ComposerField`：Mac 是主菜单项经响应链找到它，iPad 是它的按键命令），所以只在回复框聚焦时可用。
enum ReplyShortcut: Int, CaseIterable {
    case send
    case model
    case thinking
    case recall

    var title: String {
        switch self {
        case .send: String(localized: "发送")
        case .model: String(localized: "选择模型…")
        case .thinking: String(localized: "选择思考强度…")
        case .recall: String(localized: "调回上一句")
        }
    }

    /// 主键（都带 ⌘，`shift` 时再加 ⇧）："\r" 是回车；`recall` 是不带修饰的 ↑，由文字区自己的按键处理接（见 `Composer`），不进菜单。
    var input: String {
        switch self {
        case .send: "\r"
        case .model: "m"
        case .thinking: "e"
        case .recall: ""
        }
    }

    var shift: Bool { self == .model || self == .thinking }

    var symbols: String {
        switch self {
        case .recall: "↑"
        case .send, .model, .thinking: "⌘" + (shift ? "⇧" : "") + (input == "\r" ? "↩" : input.uppercased())
        }
    }

    static var menu: [ReplyShortcut] { allCases.filter { $0 != .recall } }
}
