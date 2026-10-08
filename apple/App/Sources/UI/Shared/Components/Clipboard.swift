#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 把一段纯文字放进系统剪贴板（不写发送记录；复制整张卡见 `Workspace.copy`）。
@MainActor
enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
