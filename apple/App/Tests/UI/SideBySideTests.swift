import CueStore
import Foundation
import Testing
@testable import CuePad

/// 宽屏主区右半（第二个会话；Mac 上还有活预览）开着时的排布，与 Agent 用 `cuepad live` 交来的地址落在哪。
@Suite(.releasesLibraries)
struct SideBySideTests {
    let rig = TestApp()
    var services: AppServices { rig.services }

    private func wide() -> Workspace {
        let workspace = Workspace(services: services)
        workspace.setLayout(.wide)
        return workspace
    }

    private func open(_ sessionID: String, in column: Workspace.Column = .main, _ workspace: Workspace) {
        workspace.openSession(SessionState.recordID(sessionID: sessionID), sessionID: sessionID, in: column)
    }

    /// 放得下会话条、一个会话与 Cue 的窗口。
    private func cueShown(_ workspace: Workspace) -> Bool { workspace.cueShown(WideMetrics(width: 1600, workspace: workspace)) }

    @Test func 右半开着时Cue收成钮_收起右半回到原来的选择_选择本身没被改() {
        services.settings.cueOpen = true
        let workspace = wide()
        open("a", workspace)
        #expect(cueShown(workspace))

        open("b", in: .beside, workspace)
        #expect(!cueShown(workspace) && services.settings.cueOpen)
        workspace.closeColumn(.beside)
        #expect(cueShown(workspace))

        #if os(macOS)
        workspace.toggleLivePreview()
        #expect(workspace.beside == .preview && !cueShown(workspace) && services.settings.cueOpen)
        workspace.toggleLivePreview()
        #expect(cueShown(workspace))
        #endif

        services.settings.cueOpen = false
        open("b", in: .beside, workspace)
        workspace.closeColumn(.beside)
        #expect(!cueShown(workspace) && !services.settings.cueOpen)
    }
}

#if os(macOS)
@Suite(.releasesLibraries)
struct LivePreviewFlowTests {
    let rig = TestApp()
    var services: AppServices { rig.services }
    var store: CueStore { services.store }

    private func wide() -> Workspace {
        let workspace = Workspace(services: services)
        workspace.setLayout(.wide)
        return workspace
    }

    private func open(_ sessionID: String, in column: Workspace.Column = .main, _ workspace: Workspace) {
        workspace.openSession(SessionState.recordID(sessionID: sessionID), sessionID: sessionID, in: column)
    }

    private func id(_ sessionID: String) -> UUID { SessionState.recordID(sessionID: sessionID) }

    /// 同 `cuepad live`：命令行只往资料库写这一条，App 读到了再处理。
    private func live(_ address: String, for sessionID: String) async throws -> URL {
        let url = try #require(URL(string: address))
        try await store.sendLive(url, to: sessionID, found: false)
        return url
    }

    /// 本机这台上的一个会话：状态记录与带工作目录的索引（认服务按目录归属时读它）。
    private func session(_ sessionID: String, _ state: WorkState, in directory: URL) async throws -> SessionState {
        let recorder = try await rig.runtimeRecorder(on: services.hostID)
        try await recorder.update(sessionID: sessionID, state: state, title: sessionID)
        try await store.upsertSessions(
            [SessionUpsert(session: IndexedSession(id: sessionID, path: directory.appending(path: "s.jsonl").path, cwd: directory.path, lastActivityAt: .now), checkpoint: nil, transcript: nil)],
            host: services.hostID)
        return try #require(try await store.sessionState(sessionID))
    }

    /// 在这个目录里起一个本机网页服务（Python 自带的目录页，回 HTML），返回它和它的地址。
    private func serve(in directory: URL) async throws -> (Process, URL) {
        let server = Process()
        server.executableURL = URL(filePath: "/usr/bin/python3")
        server.arguments = ["-u", "-m", "http.server", "0", "--bind", "127.0.0.1"]
        server.currentDirectoryURL = directory
        let out = Pipe()
        server.standardOutput = out
        try server.run()
        // 起来时打印一行 "Serving HTTP on 127.0.0.1 port 54321 …"
        var port: Int?
        for try await line in out.fileHandleForReading.bytes.lines {
            port = line.split(separator: " ").drop { $0 != "port" }.dropFirst().first.flatMap { Int($0) }
            if port != nil { break }
        }
        return (server, try #require(port.flatMap { URL(string: "http://localhost:\($0)") }))
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "live-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func 没有服务也没有地址的会话栏头没有预览钮_菜单里手动打开是空的地址输入_收起后钮又不在() async throws {
        let workspace = wide()
        let quiet = try await session("quiet", .settled, in: try folder())
        open("quiet", workspace)
        #expect(workspace.liveButton(quiet.id) == nil)

        workspace.openLivePreview(quiet)
        #expect(workspace.beside == .preview && workspace.liveButton(quiet.id) == .open(nil) && !workspace.hasLivePage(quiet.id))
        workspace.toggleLivePreview()
        #expect(workspace.beside == nil && workspace.liveButton(quiet.id) == nil)
    }

    @Test func 认出会话目录里的服务_栏头的钮与会话条的标出现_已结束的会话不认() async throws {
        let workspace = wide()
        let liveDir = try folder(), doneDir = try folder()
        let live = try await session("live", .settled, in: liveDir)
        let done = try await session("done", .ended, in: doneDir)
        open("live", workspace)
        let (first, url) = try await serve(in: liveDir)
        let (second, _) = try await serve(in: doneDir)
        defer { first.terminate(); second.terminate() }
        let scanning = Task { await workspace.watchLiveServers() }
        defer { await scanning.stop() }

        try await eventually("栏头出现指着这个服务的钮") { workspace.liveButton(live.id) == .closed(url) }
        #expect(workspace.hasLivePage(live.id))
        #expect(!workspace.hasLivePage(done.id) && workspace.liveButton(done.id) == nil)

        workspace.toggleLivePreview()
        #expect(workspace.livePreviews[live.id]?.address == url)
    }

    @Test func 左边换会话或离开会话页_预览收起_开着预览时并排第二个会话_会话换掉预览() {
        let workspace = wide()
        open("a", workspace)
        workspace.toggleLivePreview()
        open("b", workspace)
        #expect(workspace.beside == nil)

        workspace.toggleLivePreview()
        workspace.select(.shelf)
        #expect(workspace.beside == nil)

        open("a", workspace)
        workspace.toggleLivePreview()
        open("b", in: .beside, workspace)
        #expect(workspace.session(in: .beside)?.id == id("b") && workspace.beside != .preview)
    }

    @Test func live_会话在主区且右半空着就打开_不在主区只亮栏头的钮_右半开着别的会话不换掉() async throws {
        let workspace = wide()
        let following = Task { await workspace.follow() }
        defer { await following.stop() }

        open("a", workspace)
        let first = try await live("http://localhost:5173", for: "a")
        try await eventually("预览打开在 Agent 给的地址") { workspace.beside == .preview && workspace.livePreviews[id("a")]?.address == first }

        workspace.toggleLivePreview()
        open("b", workspace)
        let second = try await live("http://localhost:3000", for: "a")
        try await eventually("a 的钮亮起、指着新地址") { workspace.liveButton(id("a")) == .closed(second) }
        #expect(workspace.session(in: .main)?.id == id("b") && workspace.beside == nil)

        open("c", in: .beside, workspace)
        let third = try await live("http://localhost:4000", for: "b")
        try await eventually("b 的钮亮起") { workspace.liveButton(id("b")) == .closed(third) }
        #expect(workspace.session(in: .beside)?.id == id("c"))
    }

    @Test func live_你手输的正开着的地址不被顶掉_收起再开才换成Agent给的() async throws {
        let workspace = wide()
        let following = Task { await workspace.follow() }
        defer { await following.stop() }
        open("a", workspace)
        workspace.toggleLivePreview()
        let preview = try #require(workspace.livePreviews[id("a")])
        let typed = try #require(URL(string: "http://localhost:8080"))
        preview.retarget(.init(url: typed, source: .typed))

        let sent = try await live("http://localhost:5173", for: "a")
        try await eventually("App 收到了这一条") { workspace.liveSent[id("a")] == .init(url: sent, source: .sent) }
        #expect(preview.address == typed)

        workspace.toggleLivePreview()
        #expect(workspace.liveButton(id("a")) == .closed(sent))
        workspace.toggleLivePreview()
        #expect(preview.address == sent)
    }
}
#endif
