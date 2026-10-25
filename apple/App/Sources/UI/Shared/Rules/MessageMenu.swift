/// 对话里一条消息长按（Mac 右键）有哪几项、什么顺序（iOS 与 Mac 同一份，`MessageActions` 照着画）。
/// 照信息类 App 的习惯：复制排第一；Agent 的回答再加选择文本与批注（只在手机上，都打开可选文本页挑一段；Mac 直接拖选）、分享，和本 App 的主动线"存为灵感"；
/// 你的话加"编辑后重发"（放回输入框）。Cue 页里的话（Cue 的与你的）复制、选择文本、分享，不进哪个会话（批注只属于会话）。还没进对话的话（发出中、没能送达）：复制、没能送达时重发，移除单独一组在最后。
/// 长按的预览就是消息本身（系统截图），不另画一份。
nonisolated enum MessageMenu {
    enum Kind: Equatable, Sendable {
        case reply, mine
        case outgoing(failed: Bool)
        /// Cue 页里的一句（Cue 的或你的）：只有拿走文字的几项，不进哪个会话。
        case cue
    }

    enum Item: Hashable, Sendable {
        case copy, selectText, annotate, share, saveAsIdea, editAgain, resend, remove
    }

    /// 组间画分隔线。
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
