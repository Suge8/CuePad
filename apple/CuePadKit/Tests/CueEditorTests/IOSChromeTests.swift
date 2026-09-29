#if canImport(UIKit)
import CueText
import Testing
import UIKit
@testable import CueEditor

@MainActor
@Suite("iOS 键盘工具栏与布局")
struct IOSChromeTests {
    private func item(_ label: String, in h: EditorHarness) throws -> UIBarButtonItem {
        let toolbar = try #require(h.textView.inputAccessoryView as? UIToolbar)
        return try #require(toolbar.items?.first { $0.accessibilityLabel == label })
    }

    private func tap(_ item: UIBarButtonItem) {
        item.primaryAction?.performWithSender(item, target: nil)
    }

    @Test("键盘上方工具栏：分块直接切块，插入图片与变量取值经回调交给外部")
    func toolbar() throws {
        let h = EditorHarness()
        h.load("甲乙")
        h.setCaret(1)
        var requests: [String] = []
        h.textView.onInsertImageRequest = { requests.append("image") }
        h.textView.onVariablesRequest = { requests.append("variables") }

        tap(try item("插入图片", in: h))
        tap(try item("变量取值", in: h))
        #expect(requests == ["image", "variables"])

        tap(try item("分块", in: h))
        #expect(h.stored == "甲\n\(CueFormat.splitMarker)\n乙")
    }

    @Test("长文档的总高度在加载完成后即稳定，滚动不再让滚动条跳变")
    func heightStable() async throws {
        let h = EditorHarness(height: 640)
        var stored = ""
        let line = String(repeating: "这是一段用来测试排版的中文文字，", count: 8)
        for i in 0..<400 {
            stored += line + "\n"
            if i % 40 == 39 {
                let color = UIColor(hue: CGFloat(i) / 400, saturation: 0.7, brightness: 0.9, alpha: 1)
                stored += "![](cuepad://img/\(try h.store.store(makePNG(width: 1600, height: 1000, color: color))))\n"
            }
        }
        h.load(stored)
        var last = -1.0, stableCount = 0
        #expect(await h.wait(timeout: 15) {
            let current = Double(h.textView.contentSize.height)
            stableCount = current == last ? stableCount + 1 : 0
            last = current
            return stableCount >= 25
        })
        let settled = h.textView.contentSize.height

        var y: CGFloat = 0
        while y < h.textView.contentSize.height {
            h.textView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            h.layout()
            y += 400
        }
        let afterScroll = h.textView.contentSize.height
        #expect(abs(afterScroll - settled) / afterScroll < 0.02)
    }
}
#endif
