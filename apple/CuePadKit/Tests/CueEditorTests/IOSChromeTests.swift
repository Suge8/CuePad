#if canImport(UIKit)
import CueText
import Testing
import UIKit
@testable import CueEditor

@MainActor
@Suite("iOS 布局")
struct IOSChromeTests {
    @Test("长文档的总高度在加载完成后即稳定，滚动不再让滚动条跳变")
    func heightStable() async throws {
        let h = EditorHarness(height: 640)
        var stored = ""
        let line = String(repeating: "这是一段用来测试排版的中文文字，", count: 8)
        for i in 0..<400 {
            stored += line + "\n"
            if i % 40 == 39 {
                let color = UIColor(hue: CGFloat(i) / 400, saturation: 0.7, brightness: 0.9, alpha: 1)
                stored += "![](cuepad://file/\(try h.store.store(makePNG(width: 1600, height: 1000, color: color))))\n"
            }
        }
        h.load(stored)
        #expect(await h.wait { laidOutToTheEnd(h.textView.textLayoutManager!) })
        h.layout()
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
