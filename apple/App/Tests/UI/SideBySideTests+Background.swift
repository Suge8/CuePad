import CueStore
import Foundation
import Testing
@testable import CuePad

#if os(macOS)
extension LivePreviewFlowTests {
    /// 没开在面板里的页面，Agent 用着时照开着的跑：动画帧在走、页面说自己看得见（不然靠 requestAnimationFrame 出内容的页面 Agent 等不到）。
    /// 交的文件是命令行读出的内容，App 写进这个预览自己的目录再给页面，预览释放时删掉。
    @Test func Agent操作_后台的页面像开着一样跑_交的文件页面读得到_释放时删掉() async throws {
        let workspace = wide()
        let following = Task { await workspace.follow() }
        defer { await following.stop() }
        let (server, _) = try await backgroundPage(workspace)
        defer { server.terminate() }

        let frames = await agent(workspace, "eval", .init(code: """
            return await new Promise(done => {
                let n = 0;
                (function tick() { n++; requestAnimationFrame(tick) })();
                setTimeout(() => done([document.visibilityState, n > 5]), 500);
            })
            """))
        #expect(frames.text == "[\"visible\",true]")

        _ = await agent(workspace, "eval", .init(code: "document.body.insertAdjacentHTML('beforeend', '<label>附件<input type=file id=f></label>')"))
        let page = await agent(workspace, "snapshot")
        let field = try ref("[file]", in: page.text)
        let sent = await agent(workspace, "upload", .init(ref: field, files: [.init(name: "说明.txt", data: Data("你好".utf8))]))
        #expect(!sent.failed && sent.text.hasSuffix("交了 1 个文件：说明.txt"), "\(sent.text)")
        #expect(await agent(workspace, "eval", .init(code: "const f = document.getElementById('f').files[0]; return [f.name, await f.text()]")).text == "[\"说明.txt\",\"你好\"]")

        let kept = try #require(workspace.livePreviews[id("a")]).uploadFolder
        #expect(FileManager.default.fileExists(atPath: kept.path))
        await workspace.releaseLivePreviews(at: .now + Workspace.liveIdle + .seconds(1))
        try await eventually("释放后交过的文件删了") { !FileManager.default.fileExists(atPath: kept.path) }
    }
}
#endif
