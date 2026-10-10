#if os(iOS)
import UIKit

/// 系统剪贴板（复制不是发送，不写发送记录；复制整张卡见 `Workspace.copy`）。
@MainActor
enum Clipboard {
    /// 一段纯文字。
    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}
#endif
