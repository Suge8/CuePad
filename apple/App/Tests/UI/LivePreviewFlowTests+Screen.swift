#if os(macOS)
import CoreVideo
import CueScreen
import CueStore
import CueTestSupport
import Foundation
import Synchronization
import Testing
@testable import CuePad

extension LivePreviewFlowTests {
    /// 一个 Mac 应用的替身：一颗钮、点了几下的字、一个收字的框、一个不收的框。真应用那头是注入库走无障碍树、造鼠标键盘事件（`WindowScreen`），
    /// 这里只替掉它；那张页（`ScreenPage`）、服务（`ScreenServer`）与 App 替 Agent 做的那几样都是真的。
    private final class Desk: ScreenSource {
        struct State {
            var taps = 0
            var kept = ""
            var keys: [UInt32] = []
        }
        let state = Mutex(State())
        func watch(_ changed: @escaping @Sendable () -> Void) {}
        func rest() {}
        func frame() -> CVPixelBuffer? { nil }

        func send(_ input: ScreenInput) {
            state.withLock {
                switch input {
                case .touch(.down, let x, let y) where (0.1...0.4).contains(x) && (0.1...0.3).contains(y): $0.taps += 1
                case .fill(3, let text): $0.kept = text
                case .key(let usage, true): $0.keys.append(usage)
                default: break
                }
            }
        }

        func outline(_ reply: @escaping @Sendable (Data?) -> Void) {
            let now = state.withLock { $0 }
            let nodes: [[String: Any]] = [
                ["i": 1, "r": "button", "n": "点我", "b": [0.1, 0.1, 0.3, 0.2]],
                ["i": 2, "r": "text", "n": "点了 \(now.taps) 下", "b": [0.5, 0.1, 0.4, 0.2]],
                ["i": 3, "r": "textbox", "hint": "收下", "v": now.kept, "b": [0.1, 0.4, 0.8, 0.2]],
                ["i": 4, "r": "textbox", "hint": "不收", "v": "", "b": [0.1, 0.7, 0.8, 0.2]],
            ]
            reply(try? JSONSerialization.data(withJSONObject: ["points": 600, "ms": 1, "nodes": [["i": 0, "r": "window", "n": "替身", "b": [0, 0, 1, 1], "k": nodes]]]))
        }
    }

    /// `cuepad live app` 开进预览的 Mac 应用：Agent 一开进来就读得到它的元素，点下去落在应用里的那个控件上、等得到它变了的字，
    /// 填的字应用收下了才报填成了、没收下的回执里说，按一个键应用只收到一下。
    @Test func Agent操作_Mac应用的那张页_读得到_点和填都到应用_没收下的字回执里说_按键只到一下() async throws {
        let workspace = wide()
        let following = Task { await workspace.follow() }
        defer { await following.stop() }
        let desk = Desk()
        // 口被占着就换下一个，试几个为止
        var port = UInt16.random(in: 49152...65000), server: ScreenServer?
        for _ in 0..<8 where server == nil {
            port += 1
            let candidate = try ScreenServer(source: desk, port: port, identity: "test", page: ScreenPage.html(title: "替身", kind: .desktop))
            if (try? await candidate.start()) != nil { server = candidate }
        }
        try #require(server != nil, "试了 8 个口，服务都没起来")
        workspace.openSession(id("b"), sessionID: "b", in: .main)
        _ = try await live("http://127.0.0.1:\(port)/", for: "a")
        try await eventually("后台建好了 a 的预览") { workspace.livePreviews[id("a")]?.web.title == "替身" }

        let page = await agent(workspace, "snapshot")
        #expect(page.text.contains("button \"点我\""), "\(page.text)")

        let clicked = await agent(workspace, "click", .init(ref: try ref("button \"点我\"", in: page.text)))
        #expect(clicked.text.contains("点了 button \"点我\""), "\(clicked.text)")
        let waited = await agent(workspace, "wait", .init(text: "点了 1 下", timeout: 5))
        #expect(waited.text.contains("等到了"), "\(waited.text)")

        let kept = await agent(workspace, "fill", .init(ref: try ref("textbox \"收下\"", in: page.text), text: "abc"))
        #expect(kept.text == "textbox \"收下\" 填成了 \"abc\"")
        #expect(desk.state.withLock { $0.kept } == "abc")
        let spat = await agent(workspace, "fill", .init(ref: try ref("textbox \"不收\"", in: page.text), text: "abc"))
        #expect(spat.text.contains("不是填的这段"), "\(spat.text)")

        _ = await agent(workspace, "press", .init(ref: try ref("textbox \"收下\"", in: page.text), key: "Backspace"))
        // 输入照先后到：后面这一下点到了，退格的那几下就都到过了
        _ = await agent(workspace, "click", .init(ref: try ref("button \"点我\"", in: page.text)))
        try await eventually("后面的那一下点到了应用") { desk.state.withLock { $0.taps } == 2 }
        #expect(desk.state.withLock { $0.keys } == [42])
        _ = server
    }
}
#endif
