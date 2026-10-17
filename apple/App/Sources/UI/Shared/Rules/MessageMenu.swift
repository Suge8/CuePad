/// 对话里一条消息长按（Mac 右键）有哪几项、什么顺序（iOS 与 Mac 同一份，`MessageActions` 照着画）。
/// 照信息类 App 的习惯：复制排第一；Agent 的回答再加选择文本（只在手机上，长回答里挑一句；Mac 直接拖选）、分享，和本 App 的主动线"存为灵感"；
/// 你的话加"编辑后重发"（放回输入框）。Cue 页里的话（Cue 的与你的）复制、选择文本、分享，不进哪个会话。还没进对话的话（发出中、没能送达）：复制、没能送达时重发，移除单独一组在最后。
/// 长按的预览就是消息本身（系统截图），不另画一份。
nonisolated enum MessageMenu {
    enum Kind: Equatable, Sendable {
        case reply, mine
        case outgoing(failed: Bool)
        /// Cue 页里的一句（Cue 的或你的）：只有拿走文字的几项，不进哪个会话。
        case cue
    }

    enum Item: Hashable, Sendable {
        case copy, selectText, share, saveAsIdea, editAgain, resend, remove
    }

    /// 组间画分隔线。
    static func sections(for kind: Kind) -> [[Item]] {
        switch kind {
        case .reply:
            #if os(iOS)
            [[.copy, .selectText, .share], [.saveAsIdea]]
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
        case .copy: "复制"
        case .selectText: "选择文本"
        case .share: "分享"
        case .saveAsIdea: "存为灵感"
        case .editAgain: "编辑后重发"
        case .resend: "重发"
        case .remove: "移除"
        }
    }

    var symbol: String {
        switch self {
        case .copy: "doc.on.doc"
        case .selectText: "selection.pin.in.out"
        case .share: "square.and.arrow.up"
        case .saveAsIdea: "square.and.arrow.down"
        case .editAgain: "square.and.pencil"
        case .resend: "arrow.clockwise"
        case .remove: "xmark"
        }
    }
}
