import SwiftUI

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
