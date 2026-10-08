import SwiftUI

/// "导出诊断"：把诊断文本复制到剪贴板（读不出资料库页与上次崩溃共用），点过变"已复制"。
struct ExportDiagnosticsButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "已复制" : "导出诊断") {
            Clipboard.copy(text)
            copied = true
        }
    }
}
