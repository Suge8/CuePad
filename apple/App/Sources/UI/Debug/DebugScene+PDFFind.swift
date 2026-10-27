#if DEBUG
import SwiftUI
#if os(macOS)
import AppKit
#else
import PDFKit
#endif

extension DebugScene {
    /// `-CuePadPDFFind <词>`：全屏页里的 PDF 一出来就打开查找条（Mac 按 ⌘F，iPhone 同点搜索钮）、搜这个词（拍"搜索框打开的样子"）。只搜一次。
    private static var pdfFound = false

    #if os(macOS)
    static func findInPDF(_ host: PDFFindHost) {
        guard !pdfFound, let word = defaults.string(forKey: "CuePadPDFFind") else { return }
        pdfFound = true
        // 同按 ⌘F：主菜单"查找…"那一项从窗口此刻的焦点沿响应链找接得住的（后台窗口不是 key，菜单的快捷键到不了，这里直接从焦点发）
        later(.milliseconds(600)) {
            guard let item = NSApp.mainMenu?.items.lazy.compactMap({ $0.submenu?.items.first { $0.keyEquivalent == "f" } }).first,
                  let action = item.action
            else { return }
            _ = host.window?.firstResponder?.tryToPerform(action, with: item)
        }
        // 查找条是系统的视图：等它出来、排好，在它的搜索框里填上词再发它的动作，同打字
        later(.milliseconds(1200)) {
            guard let field = host.findBarView.flatMap(searchField) else { return }
            field.stringValue = word
            field.sendAction(field.action, to: field.target)
        }
    }

    private static func searchField(in view: NSView) -> NSSearchField? {
        (view as? NSSearchField) ?? view.subviews.lazy.compactMap(searchField).first
    }
    #else
    static func findInPDF(_ view: PDFView) {
        guard !pdfFound, let word = defaults.string(forKey: "CuePadPDFFind") else { return }
        pdfFound = true
        later(.seconds(1.2)) {
            view.findInteraction.searchText = word
            view.findInteraction.presentFindNavigator(showingReplace: false)
        }
    }
    #endif
}
#endif
