import SwiftUI

struct DialogButton: Identifiable {
    let title: LocalizedStringResource
    var role: ButtonRole?
    var disabled = false
    let action: @MainActor () -> Void

    var id: String { title.key }
}

struct DialogField {
    let prompt: LocalizedStringResource
    let text: Binding<String>
}

// 调用处只给状态、文案与按钮，平台只换呈现：Mac 不用系统提示框，它也是窗口 sheet，开、关各占主线程约 300ms，所以是 `panel` 里的一张小卡（`DialogCard`）。
