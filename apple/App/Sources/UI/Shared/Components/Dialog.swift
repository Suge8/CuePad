import SwiftUI

/// 确认框与提示框里的一颗按钮；按下后框自己关。
struct DialogButton: Identifiable {
    let title: LocalizedStringResource
    var role: ButtonRole?
    var disabled = false
    let action: @MainActor () -> Void

    var id: String { title.key }
}

/// 提示框里要写一行字时（如新建任务的名字）。
struct DialogField {
    let prompt: LocalizedStringResource
    let text: Binding<String>
}

// 确认框与提示框 `dialog(_:isPresented:message:field:buttons:)`、对某一项的确认 `dialog(_:item:message:buttons:)`（`item` 非空时弹出，
// 关掉时置回 nil）：调用处只给状态、文案与按钮，平台只换呈现。iOS 是系统的（带输入框时是 alert，否则是 confirmationDialog）；
// Mac 是 `panel` 里的一张小卡（`DialogCard`）——Mac 的系统提示框也是窗口 sheet，开、关各占主线程约 300ms。
