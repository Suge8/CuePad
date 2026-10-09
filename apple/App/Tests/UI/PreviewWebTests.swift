import Foundation
import Network
import Testing
import WebKit
@testable import CuePad

/// 手机上预览的网页：脚本能跑，但联网请求一律被拦掉（页面里的 fetch、图片都到不了网络）。
/// 用本机的一个监听端口当"外网"：没有拦截规则的对照页面请求能到，装了规则的请求到不了。
@MainActor
struct PreviewWebTests {
    /// 记录收到几个连接的本机端口
    private nonisolated final class Probe: @unchecked Sendable {
        private let listener = try! NWListener(using: .tcp, on: .any)
        private let lock = NSLock()
        private var count = 0
        var hits: Int { lock.withLock { count } }
        var port: UInt16 { listener.port!.rawValue }

        init() async {
            listener.newConnectionHandler = { [self] connection in
                lock.withLock { count += 1 }
                connection.start(queue: .global())
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nAccess-Control-Allow-Origin: *\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
            await withCheckedContinuation { continuation in
                listener.stateUpdateHandler = { if $0 == .ready { continuation.resume() } }
                listener.start(queue: .global())
            }
        }

        deinit { listener.cancel() }
    }

    private func page(reaching port: UInt16) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "preview-web-\(UUID().uuidString).html")
        try """
            <script>
            fetch('http://127.0.0.1:\(port)/data').then(() => document.title = 'reached', () => document.title = 'blocked');
            </script><img src="http://127.0.0.1:\(port)/a.png"><p id="x">内联脚本在跑</p><script>document.getElementById('x').dataset.ran = 'yes'</script>
            """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func settledTitle(_ web: WKWebView) async throws -> String {
        var title = ""
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, title.isEmpty {
            title = try await web.evaluateJavaScript("document.title") as? String ?? ""
            if title.isEmpty { try await Task.sleep(for: .milliseconds(30)) }
        }
        return title
    }

    @Test func 联网请求被拦掉_内联脚本照跑_对照组的请求能到() async throws {
        let probe = await Probe()
        let file = try page(reaching: probe.port)

        let control = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        control.load(try Data(contentsOf: file), mimeType: "text/html", characterEncodingName: "utf-8", baseURL: URL(string: "about:blank")!)
        #expect(try await settledTitle(control) == "reached" && probe.hits > 0)  // 没有规则：请求到了，说明这个探针有效

        let before = probe.hits
        let delegate = PreviewWebGuard.Coordinator()  // 网页视图只弱引用代理
        let guarded = PreviewWebGuard.makeWebView(file: file, rules: try await PreviewWebGuard.rules(), delegate: delegate)
        defer { withExtendedLifetime(delegate) {} }
        #expect(try await settledTitle(guarded) == "blocked")
        #expect(probe.hits == before)
        #expect(try await guarded.evaluateJavaScript("document.getElementById('x').dataset.ran") as? String == "yes")
    }
}
