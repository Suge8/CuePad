import Foundation

enum ReplyShortcut: Int, CaseIterable {
    case send
    case model
    case thinking

    var title: String {
        switch self {
        case .send: String(localized: "发送")
        case .model: String(localized: "选择模型…")
        case .thinking: String(localized: "选择思考强度…")
        }
    }

    var input: String {
        switch self {
        case .send: "\r"
        case .model: "m"
        case .thinking: "e"
        }
    }

    var shift: Bool { self == .model || self == .thinking }

    var symbols: String {
        switch self {
        case .send: "↩"
        case .model, .thinking: "⌘" + (shift ? "⇧" : "") + input.uppercased()
        }
    }
}
