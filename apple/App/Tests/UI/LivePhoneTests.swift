#if os(macOS)
import CryptoKit
import CueStore
import CueTestSupport
import Foundation
import Network
import Testing
@testable import CuePad

/// 手机、iPad 看这台 Mac 上会话的活预览：手机问、Mac 答（同一条"有没有页面"的规则），开着预览时经隧道取到的就是那个会话的服务、别的一概不放。
/// Mac 这头是真的工作区；手机这头是它的 `LiveRemote` 与给网页视图的代理（`LiveTunnel.Proxy`），取页面用带同一份代理配置的 URLSession。
@Suite(.releasesLibraries)
struct LivePhoneTests {
    let flow = LivePreviewFlowTests()
    let phoneApp = TestApp(host: "phone-side")

    /// Mac 的工作区与手机这头的问询接好、Mac 按节奏扫着，跑完 `body` 拆掉（两头互相攥着，不拆资料库放不掉）。
    private func paired(_ body: (Workspace, LiveRemote, LiveSignalPair) async throws -> Void) async throws {
        let workspace = flow.wide()
        let pair = LiveSignalPair(macHost: flow.services.hostID)
        flow.services.liveSignaling = pair.mac
        let remote = LiveRemote(store: phoneApp.services.store, settings: phoneApp.services.settings) { pair.phone }
        pair.phone.deliver = { await workspace.receiveLive($0) }
        pair.mac.deliver = { remote.receive($0) }
        try await phoneApp.services.store.recordMacPresence(host: flow.services.hostID) { true }
        let scanning = Task { await workspace.watchLiveServers() }
        func end() async {
            await scanning.stop()
            pair.phone.deliver = { _ in }
            pair.mac.deliver = { _ in }
            flow.services.liveSignaling = nil
            workspace.liveServer?.server.cancel()
            workspace.liveServer = nil
        }
        do { try await body(workspace, remote, pair) } catch {
            await end()
            throw error
        }
        await end()
    }

    /// 手机这头的网页视图：经代理（`LiveTunnel.Proxy`，SOCKS5 带口令）连 `localhost:<端口>` 的一条连接，同 WebKit 那样把主机名交给代理。
    /// 不用 URLSession：macOS 上它对 localhost 不走代理、直连，换成 `*.localhost` 又被 ATS 拦（都实测）。
    private struct Tab {
        let connection: NWConnection

        init(_ proxy: LiveTunnel.Proxy, port: UInt16, to url: URL) async throws {
            connection = NWConnection(host: .ipv4(.loopback), port: .init(rawValue: port)!, using: .tcp)
            try await connection.established(within: .seconds(5))
            try await connection.write(Data([5, 1, 2]))
            _ = try await connection.read(2)
            try await connection.write(Data([1, UInt8(proxy.user.utf8.count)] + proxy.user.utf8 + [UInt8(proxy.password.utf8.count)] + proxy.password.utf8))
            guard try await connection.read(2) == Data([1, 0]) else { throw LiveTunnelError.protocolMismatch }
            let host = Array("localhost".utf8), target = UInt16(url.port!)
            try await connection.write(Data([5, 1, 0, 3, UInt8(host.count)] + host + [UInt8(target >> 8), UInt8(target & 0xff)]))
            let reply = try await connection.read(10)
            guard reply[reply.startIndex + 1] == 0 else {
                connection.cancel()
                throw LiveTunnelError.closed
            }
        }

        /// 在这条连接上取一页，返回正文（服务答完就关，HTTP/1.0）。
        func get(_ path: String) async throws -> String {
            try await connection.write(Data("GET /\(path) HTTP/1.0\r\nHost: localhost\r\n\r\n".utf8))
            var received = Data()
            while true {
                let (chunk, done) = try await withCheckedThrowingContinuation { (next: CheckedContinuation<(Data?, Bool), Error>) in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
                        if let error { next.resume(throwing: error) } else { next.resume(returning: (data, complete)) }
                    }
                }
                received += chunk ?? Data()
                if done || chunk == nil { break }
            }
            connection.cancel()
            let text = String(decoding: received, as: UTF8.self)
            guard text.hasPrefix("HTTP/1.0 200"), let body = text.range(of: "\r\n\r\n") else { throw LiveTunnelError.closed }
            return String(text[body.upperBound...])
        }
    }

    private func route(_ proxy: LiveTunnel.Proxy, _ key: SymmetricKey, _ door: LiveSignal.Door, ticket: Data? = nil) {
        proxy.use(.init(key: key, ticket: ticket ?? door.ticket, mac: .hostPort(host: "127.0.0.1", port: .init(rawValue: door.port)!), addresses: []))
    }

    /// 等到读得出值。
    private func awaited<T>(_ what: String, _ read: () -> T?) async throws -> T {
        try await eventually(what) { read() != nil }
        return try #require(read())
    }

    @Test func 手机开着会话页_Mac认出服务就答有页面_服务停了答没有_别处的会话不答() async throws {
        try await paired { _, remote, _ in
        let directory = try flow.folder()
        _ = try await flow.session("live", .settled, in: directory)
        let watching = Task { await remote.watch("live", on: flow.services.hostID) }
        let elsewhere = Task { await remote.watch("other-mac", on: "another-mac") }

        await quietPeriod(.milliseconds(300))
        #expect(remote.answers["live"] == nil)
        let (server, url) = try await flow.serve(in: directory)
        try await eventually("手机收到 Mac 认出的这一页") { remote.answers["live"]?.pages == [url] }
        #expect(remote.answers["live"]?.door == nil)
        #expect(remote.answers["other-mac"] == nil && remote.offline.contains("other-mac"))

        server.terminate()
        try await eventually("服务停了，手机这头的钮跟着没了") { remote.answers["live"] == nil }
        await watching.stop()
        await elsewhere.stop()
        }
    }

    @Test func 手机要用UU远程看_Mac把会话开到主区_有页面开活预览铺满窗口_回来了放回右半_别处的与结束的不动() async throws {
        try await paired { workspace, _, pair in
        let directory = try flow.folder()
        _ = try await flow.session("live", .settled, in: directory)
        _ = try await flow.session("plain", .settled, in: try flow.folder())
        _ = try await flow.session("done", .ended, in: try flow.folder())
        try await (flow.rig.runtimeRecorder(on: "other-mac")).update(sessionID: "elsewhere", state: .settled, title: "elsewhere")
        let (server, url) = try await flow.serve(in: directory)
        defer { server.terminate() }
        func show(_ sessionID: String) async throws {
            try await pair.phone.sendVoice(.live(signal: .show(request: UUID(), session: sessionID)), session: VoiceSessionID(UUID()), to: pair.mac.local)
        }
        func back(_ sessionID: String) async throws {
            try await pair.phone.sendVoice(.live(signal: .back(request: UUID(), session: sessionID)), session: VoiceSessionID(UUID()), to: pair.mac.local)
        }
        // 预览占窗口多宽：铺满是整个窗口
        @MainActor func previewWidth() -> CGFloat { WideMetrics(width: 1600, workspace: workspace).trailing }

        try await show("plain")
        try await eventually("没有页面的会话只开到主区") { workspace.session(in: .main)?.sessionID == "plain" }
        #expect(workspace.beside == nil)

        try await show("live")
        try await eventually("开到主区、它的活预览铺满窗口") {
            workspace.session(in: .main)?.sessionID == "live" && workspace.beside == .preview && workspace.livePreviews[flow.id("live")]?.address == url && previewWidth() == 1600
        }
        try await back("plain")
        await quietPeriod(.milliseconds(300))
        #expect(previewWidth() == 1600, "别的会话回来不算")
        try await back("live")
        try await eventually("手机回到 CuePad：预览放回右半") { previewWidth() < 1600 }
        #expect(workspace.beside == .preview && workspace.session(in: .main)?.sessionID == "live")

        try await show("live")
        try await eventually("再看一次又铺满") { previewWidth() == 1600 }
        workspace.toggleLiveFill()
        #expect(previewWidth() < 1600 && workspace.beside == .preview, "预览栏开头那颗钮放回右半")

        workspace.toggleLiveFill()
        #expect(previewWidth() == 1600, "没人远程看着时那颗钮是放大：盖过左边的会话")
        try await back("live")
        await quietPeriod(.milliseconds(300))
        #expect(previewWidth() == 1600, "你自己放大的，手机回来不收")
        workspace.toggleLiveFill()
        #expect(previewWidth() < 1600)

        try await show("live")
        try await eventually("铺满") { previewWidth() == 1600 }
        workspace.toggleLivePreview()
        workspace.toggleLivePreview()
        #expect(previewWidth() < 1600, "收起过就不再铺满")

        workspace.goHome()
        try await show("live")
        try await eventually("Cue 铺满着时也让出来") { if case .wide(let state) = workspace.navigation { !state.home } else { false } }
        workspace.showEditor(UUID())
        try await show("live")
        try await eventually("盖着编辑页时揭开") { workspace.overlay == nil }
        #expect(workspace.beside == .preview)

        try await show("done")
        try await show("elsewhere")
        await quietPeriod(.milliseconds(500))
        #expect(workspace.session(in: .main)?.sessionID == "live" && workspace.beside == .preview, "别处的、结束了的会话不动")
        }
    }

    @Test func 开着预览_经隧道取到这个会话的页面与接口_别的会话的服务与不认的票据都进不来() async throws {
        try await paired { workspace, remote, pair in
        let mine = try flow.folder(), theirs = try flow.folder()
        _ = try await flow.session("live", .settled, in: mine)
        _ = try await flow.session("theirs", .settled, in: theirs)
        let (page, url) = try await flow.serve(in: mine)
        let (other, otherURL) = try await flow.serve(in: theirs)
        defer { page.terminate(); other.terminate() }
        try "会话里的页面".write(to: mine.appending(path: "index.html"), atomically: true, encoding: .utf8)
        try "别的会话".write(to: theirs.appending(path: "index.html"), atomically: true, encoding: .utf8)

        let watching = Task { await remote.watch("live", on: flow.services.hostID, open: true) }
        let door = try await awaited("Mac 给了隧道的入口") { remote.answers["live"]?.door }
        let proxy = try LiveTunnel.Proxy()
        defer { proxy.cancel() }
        let port = try await proxy.start()
        route(proxy, pair.phone.key, door)

        #expect(try await Tab(proxy, port: port, to: url).get("index.html") == "会话里的页面")
        try await eventually("取完的那条不再记在隧道口的账上") { workspace.liveServer?.server.connections == 0 }
        await #expect(throws: (any Error).self) { try await Tab(proxy, port: port, to: otherURL) }

        route(proxy, pair.phone.key, door, ticket: Data(count: 16))
        await #expect(throws: (any Error).self) { try await Tab(proxy, port: port, to: url) }
        await watching.stop()
        }
    }

    @Test func 同号端口上另一个会话的服务在另一族回环上_手机只说得出端口_连到的还是这个会话的() async throws {
        try await paired { _, remote, pair in
        let mine = try flow.folder(), theirs = try flow.folder()
        _ = try await flow.session("live", .settled, in: mine)
        _ = try await flow.session("theirs", .settled, in: theirs)
        let (page, url) = try await flow.serve(in: mine)
        let (other, _) = try await flow.serve(in: theirs, bind: "::1", port: try #require(url.port))
        defer { page.terminate(); other.terminate() }
        try "会话里的页面".write(to: mine.appending(path: "index.html"), atomically: true, encoding: .utf8)
        try "别的会话".write(to: theirs.appending(path: "index.html"), atomically: true, encoding: .utf8)

        let watching = Task { await remote.watch("live", on: flow.services.hostID, open: true) }
        let door = try await awaited("Mac 给了隧道的入口") { remote.answers["live"]?.door }
        let proxy = try LiveTunnel.Proxy()
        defer { proxy.cancel() }
        let port = try await proxy.start()
        route(proxy, pair.phone.key, door)
        for _ in 0..<3 { #expect(try await Tab(proxy, port: port, to: url).get("index.html") == "会话里的页面") }
        await watching.stop()
        }
    }

    @Test func 别的会话在另一族回环上占了同号的口_这个会话答过HTTP的口不掉出放行() async throws {
        let mine = try flow.folder(), theirs = try flow.folder()
        let owners = ["live": LiveServers.Owner(process: nil, directory: mine.path), "theirs": LiveServers.Owner(process: nil, directory: theirs.path)]
        let (page, url) = try await flow.serve(in: mine)
        defer { page.terminate() }
        let port = try #require(url.port)
        var scanner = LiveServers()
        #expect(await scanner.find(for: owners)["live"]?.compactMap(\.port) == [port])
        // 问得到它的地址从 localhost 换成了 127.0.0.1，还没再问过：答没答过 HTTP 是记在这个进程的这个口上的
        let (other, _) = try await flow.serve(in: theirs, bind: "::1", port: port)
        defer { other.terminate() }
        #expect(await scanner.ports(for: owners, only: ["live"])["live"] == [port: "127.0.0.1"])
    }

    @Test func 会话名下不答HTTP的口_数据库那样的_隧道不放行_答了HTTP的不是网页也放行() async throws {
        try await paired { _, remote, pair in
        let directory = try flow.folder()
        _ = try await flow.session("live", .settled, in: directory)
        let (page, url) = try await flow.serve(in: directory)
        // 同一个会话起的另一个服务：接了连接，回这一句（空的就一个字不答）再关
        func serve(_ answer: String) async throws -> (Process, URL) {
            let server = Process(), out = Pipe()
            server.executableURL = URL(filePath: "/usr/bin/python3")
            server.arguments = ["-u", "-c", """
                import socket, sys
                s = socket.socket()
                s.bind(('127.0.0.1', 0))
                s.listen()
                print(s.getsockname()[1])
                while True:
                    c = s.accept()[0]
                    if sys.argv[1]: c.recv(4096); c.sendall(sys.argv[1].encode())
                    c.close()
                """, answer]
            server.currentDirectoryURL = directory
            server.standardOutput = out
            try server.run()
            var port: Int?
            for try await line in out.fileHandleForReading.bytes.lines {
                port = Int(line)
                break
            }
            return (server, try #require(port.flatMap { URL(string: "http://localhost:\($0)") }))
        }
        let (silent, database) = try await serve("")
        // 接口服务的 / 常把人转去别处；转去的那一处连不上（1 号口没人听），它自己还是答了 HTTP
        let (redirecting, api) = try await serve("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/\r\nContent-Length: 0\r\n\r\n")
        defer { page.terminate(); silent.terminate(); redirecting.terminate() }
        try "页面".write(to: directory.appending(path: "index.html"), atomically: true, encoding: .utf8)

        let watching = Task { await remote.watch("live", on: flow.services.hostID, open: true) }
        let door = try await awaited("Mac 给了隧道的入口") { remote.answers["live"]?.door }
        let proxy = try LiveTunnel.Proxy()
        defer { proxy.cancel() }
        let entry = try await proxy.start()
        route(proxy, pair.phone.key, door)
        #expect(try await Tab(proxy, port: entry, to: url).get("index.html") == "页面")
        await #expect(throws: (any Error).self) { try await Tab(proxy, port: entry, to: database) }
        _ = try await Tab(proxy, port: entry, to: api)
        #expect(remote.answers["live"]?.ports == [try #require(url.port), try #require(api.port)].sorted(), "报给手机照搬的也只有答 HTTP 的口")
        await watching.stop()
        }
    }

    @Test func 放行的口撤掉了_那个口上还连着的也断() async throws {
        try await paired { workspace, remote, pair in
        let directory = try flow.folder(), elsewhere = try flow.folder()
        _ = try await flow.session("live", .settled, in: directory)
        // 不在会话名下的服务：只因 Agent 发来这个地址才放行
        let (server, url) = try await flow.serve(in: elsewhere)
        defer { server.terminate() }
        try "页面".write(to: elsewhere.appending(path: "index.html"), atomically: true, encoding: .utf8)
        let following = Task { await workspace.followLiveAddresses() }
        _ = try await flow.live(url.absoluteString, for: "live")

        let watching = Task { await remote.watch("live", on: flow.services.hostID, open: true) }
        let door = try await awaited("Mac 给了隧道的入口") { remote.answers["live"]?.door }
        let proxy = try LiveTunnel.Proxy()
        defer { proxy.cancel() }
        let port = try await proxy.start()
        route(proxy, pair.phone.key, door)
        let held = try await Tab(proxy, port: port, to: url)
        #expect(workspace.liveServer?.server.connections == 1)

        _ = try await flow.live("http://localhost:9", for: "live")
        try await eventually("Agent 换了地址，原来那个口上连着的断了") { workspace.liveServer?.server.connections == 0 }
        await #expect(throws: (any Error).self) { try await held.get("index.html") }
        await watching.stop()
        await following.stop()
        }
    }

    @Test func 手机走了_票据作废_连着的也断_没人开着预览时隧道口关上() async throws {
        try await paired { workspace, remote, pair in
        let directory = try flow.folder()
        _ = try await flow.session("live", .settled, in: directory)
        let (server, url) = try await flow.serve(in: directory)
        defer { server.terminate() }
        try "页面".write(to: directory.appending(path: "index.html"), atomically: true, encoding: .utf8)
        let watching = Task { await remote.watch("live", on: flow.services.hostID, open: true) }
        let door = try await awaited("Mac 给了隧道的入口") { remote.answers["live"]?.door }
        let proxy = try LiveTunnel.Proxy()
        defer { proxy.cancel() }
        let port = try await proxy.start()
        route(proxy, pair.phone.key, door)
        #expect(try await Tab(proxy, port: port, to: url).get("index.html") == "页面")
        let held = try await Tab(proxy, port: port, to: url)
        try await eventually("取完的去掉、还连着的记着") { workspace.liveServer?.server.connections == 1 }

        await watching.stop()
        await workspace.receiveLive(.peerClosed(endpoint: pair.phone.local, reason: .disconnected))
        #expect(workspace.livePhones.isEmpty && workspace.liveServer == nil)
        // 网页视图早先连好、还攥着的那条也不再通
        await #expect(throws: (any Error).self) { try await held.get("index.html") }
        }
    }
}
#endif
