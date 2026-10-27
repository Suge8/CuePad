import SwiftUI
#if os(macOS)
import AppKit
#else
import PDFKit
#endif

extension DebugHooks {
    #if os(macOS)
    /// 全屏页里的 PDF 出来了（`PreviewPDF`）：`-CuePadPDFFind <词>` 在这里打开查找条、填上这个词（同按 ⌘F 再打字）。
    static func pdfShown(_ host: PDFFindHost) {
        #if DEBUG
        DebugScene.findInPDF(host)
        #endif
    }
    #else
    /// 全屏页里的 PDF 出来了（`PreviewPDF`）：`-CuePadPDFFind <词>` 在这里打开系统的查找条、填上这个词（同点页顶的搜索钮再打字）。
    static func pdfShown(_ view: PDFView) {
        #if DEBUG
        DebugScene.findInPDF(view)
        #endif
    }
    #endif
}
