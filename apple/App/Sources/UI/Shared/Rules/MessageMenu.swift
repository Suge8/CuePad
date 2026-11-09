/// 长按的预览就是消息本身（系统截图），不另画一份。
nonisolated enum MessageMenu {
    enum Kind: Equatable, Sendable {
        case reply, mine
        case outgoing(failed: Bool)
        case cue
    }

    enum Item: Hashable, Sendable {
        case copy, selectText, annotate, share, saveAsIdea, editAgain, resend, remove
    }

    static func sections(for kind: Kind) -> [[Item]] {
        switch kind {
        case .reply:
            #if os(iOS)
            [[.copy, .selectText, .annotate, .share], [.saveAsIdea]]
            #else
            [[.copy, .share], [.saveAsIdea]]
            #endif
        case .mine: [[.copy, .editAgain]]
        case .cue:
            #if os(iOS)
            [[.copy, .selectText, .share]]
            #else
            [[.copy, .share]]
            #endif
        case .outgoing(let failed): [failed ? [.copy, .resend] : [.copy], [.remove]]
        }
    }
}

extension MessageMenu.Item {
    var title: String {
        switch self {
        case .copy: String(localized: "复制")
        case .selectText: String(localized: "选择文本")
        case .annotate: String(localized: "批注")
        case .share: String(localized: "分享")
        case .saveAsIdea: String(localized: "存为灵感")
        case .editAgain: String(localized: "编辑后重发")
        case .resend: String(localized: "重发")
        case .remove: String(localized: "移除")
        }
    }

    var icon: Icon {
        switch self {
        case .copy: .copy
        case .selectText: .selectText
        case .annotate: .said
        case .share: .share
        case .saveAsIdea: .saveAsIdea
        case .editAgain: .write
        case .resend: .retry
        case .remove: .remove
        }
    }
}
