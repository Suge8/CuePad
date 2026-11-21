import CueStore
import Foundation
import Testing
@testable import CuePad

#if os(macOS)
extension LivePreviewFlowTests {
    /// 内容要现问的页面（Mac 应用的那张页：画面里有什么得问应用）：Agent 读它、点它之前先告诉它有人要读了，等它问回来，不读到一张空页、旧页。
    /// 填的字页面没收下（应用没接住、页面自己改写了），回执里要说，不报成填好了。
    @Test func Agent操作_内容要现问的页面等它问回来再读_填的字没被收下回执里说() async throws {
        let workspace = wide()
        let following = Task { await workspace.follow() }
        defer { await following.stop() }
        let directory = try folder()
        try """
            <!doctype html><meta charset="utf-8"><title>现问的页</title>
            <input aria-label="收下"><input aria-label="不收" onchange="this.dataset.spat = 1">
            <script>
            addEventListener('cuepad-read', () => {
                const spat = document.querySelector('[data-spat]');
                if (document.querySelector('button') && !spat) return;
                document.documentElement.setAttribute('aria-busy', 'true');
                setTimeout(() => {
                    if (spat) { spat.value = '原样'; delete spat.dataset.spat; }
                    else document.body.insertAdjacentHTML('beforeend', '<button>问回来的钮</button>');
                    document.documentElement.removeAttribute('aria-busy');
                }, 300);
            });
            </script>
            """.write(to: directory.appending(path: "index.html"), atomically: true, encoding: .utf8)
        let (server, url) = try await serve(in: directory)
        defer { server.terminate() }
        workspace.openSession(id("b"), sessionID: "b", in: .main)
        _ = try await live(url.absoluteString, for: "a")
        try await eventually("后台建好了 a 的预览") { workspace.livePreviews[id("a")]?.web.title == "现问的页" }

        let page = await agent(workspace, "snapshot")
        #expect(page.text.contains("button \"问回来的钮\""), "\(page.text)")
        let kept = await agent(workspace, "fill", .init(ref: try ref("textbox \"收下\"", in: page.text), text: "abc"))
        #expect(kept.text == "textbox \"收下\" 填成了 \"abc\"")
        let spat = await agent(workspace, "fill", .init(ref: try ref("textbox \"不收\"", in: page.text), text: "abc"))
        #expect(spat.text.contains("页面安定后它的值是 \"原样\"，不是填的这段"), "\(spat.text)")
    }
}
#endif
