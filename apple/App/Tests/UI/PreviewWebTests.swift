import Foundation
import Network
import Synchronization
import Testing
import WebKit
@testable import CuePad

@Suite(.releasesLibraries)
struct PreviewWebTests {
    private nonisolated final class Probe: @unchecked Sendable {
        private let listener = try! NWListener(using: .tcp, on: .any)
        private let count = Atomic(0)
        var hits: Int { count.load(ordering: .relaxed) }
        var port: UInt16 { listener.port!.rawValue }

        init() async {
            listener.newConnectionHandler = { [self] connection in
                count.add(1, ordering: .relaxed)
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
            <img id="i" src="http://127.0.0.1:\(port)/a.png"><p id="x">内联脚本在跑</p>
            <script>
            document.getElementById('x').dataset.ran = 'yes';
            const img = document.getElementById('i');
            const loaded = new Promise(done => { if (img.complete) done(); else img.onload = img.onerror = done; });
            Promise.allSettled([fetch('http://127.0.0.1:\(port)/data'), loaded])
                .then(([fetched]) => document.title = fetched.status === 'fulfilled' ? 'reached' : 'blocked');
            </script>
            """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func settledTitle(_ page: WebPage) async throws -> String {
        var title = ""
        try await eventually("页面里的请求都落定、写下标题") {
            title = try await page.callJavaScript("return document.title") as? String ?? ""
            return !title.isEmpty
        }
        return title
    }

    @Test func 联网请求被拦掉_内联脚本照跑_对照组的请求能到() async throws {
        let open = await Probe(), guardedProbe = await Probe()

        let control = WebPage()
        _ = control.load(try Data(contentsOf: try page(reaching: open.port)), mimeType: "text/html", characterEncoding: .utf8, baseURL: URL(string: "about:blank")!)
        #expect(try await settledTitle(control) == "reached" && open.hits > 0)

        let guarded = try await PreviewWebGuard.page(for: try page(reaching: guardedProbe.port))
        #expect(try await settledTitle(guarded) == "blocked")
        #expect(guardedProbe.hits == 0)
        #expect(try await guarded.callJavaScript("return document.getElementById('x').dataset.ran") as? String == "yes")
    }
}
