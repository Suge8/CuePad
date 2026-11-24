#if os(macOS)
import CueStore
import Observation
import SwiftUI
import WebKit

extension Workspace {
    func openLivePreview(_ session: SessionState) {
        if !shownSessions.contains(where: { $0.id == session.id }) { openSession(session.id, sessionID: session.sessionID, in: .main) }
        if !showsLivePreview(session.id) { toggleLivePreview(of: SessionRoute(id: session.id, sessionID: session.sessionID)) }
    }

    func livesHere(_ session: SessionState) -> Bool { Self.liveHosts(services).contains(session.hostID) }

    static func liveHosts(_ services: AppServices) -> [String] { [services.hostID] + DebugHooks.liveHosts }

    /// Agent 交来的地址（`cuepad live`、`live app`、`live sim`；不给地址时用这里认出的这个会话的服务）：后台照开着的载入，照此刻的排布滑开或只亮钮，
    /// 回执说的是实际是哪一种、开的是哪个地址。
    func openLive(_ sessionID: String, url given: URL?) async throws -> LiveChannel.Reply {
        let id = SessionState.recordID(sessionID: sessionID)
        let url: URL
        if let given {
            url = given
        } else {
            try await scanLive(only: [sessionID])
            guard let first = livePreviews.entries[id]?.found.first else {
                throw LiveRefusal("没认出这个会话起的网页服务（本机在监听、回 HTML，是这个会话里起的，或起在会话的工作目录里）。还没起来就等它起来再运行；别的会话、别处起的就给端口：cuepad live 5173")
            }
            url = first
        }
        let reply = try await openLive(sessionID, id, url: url, found: given == nil)
        return .done(reply, LiveChannel.Info(url: url.absoluteString))
    }

    private func openLive(_ sessionID: String, _ id: UUID, url: URL, found: Bool) async throws -> String {
        let here = try await services.store.sessionState(sessionID).map(livesHere) ?? false
        let shown = LiveAddress.shown(url)
        let wasShowing = showsLivePreview(id)
        let phones = "手机、iPad 与这台 Mac 在同一个网络时也看得到。"
        switch livePreviews.receive(.init(url: url, found: found, at: .now), for: id, sessionID: sessionID, showing: showsLivePreview(id)) {
        case .held(let typed):
            return "用户正开着这个会话的预览、看着他自己填的 \(LiveAddress.shown(typed))，没换掉：他收起再打开时换成 \(shown)。在那之前 cuepad live snapshot 等操作的是他那一页。"
        case .loaded(let preview):
            preview.start()
            preview.engage()
        }
        if session(in: .main)?.id == id, !isSplit { toggleLivePreview() }
        if wasShowing { return "已在这台 Mac 的 CuePad 里换成 \(shown)：用户开着的预览就是它。\(phones)" }
        if showsLivePreview(id) { return "已在这台 Mac 的 CuePad 里打开 \(shown)：会话开在主区，预览滑开了。\(phones)" }
        guard here else { return "已交给这台 Mac 上的 CuePad：\(shown)。这个会话不在这台 Mac 的 CuePad 里，用户看不到这一页；页面在后台载着，你照样能操作它。" }
        return "已交给这台 Mac 上的 CuePad：\(shown)。会话没开在主区（或右半开着别的），会话栏头的预览钮亮起、等用户点开；页面在后台载着。\(phones)"
    }

    func watchLiveServers() async {
        var failing = false
        while !Task.isCancelled {
            let everyone = services.viewer.present
            let phones = Set(livePhones.keys.map(\.sessionID))
            guard everyone || !phones.isEmpty else {
                for await busy in Observations({ self.services.viewer.present || !self.livePhones.isEmpty }) where busy { break }
                continue
            }
            do {
                try await scanLive(only: everyone ? nil : phones)
                try await answerLivePhones()
                failing = false
            } catch {
                // 每 2 秒一遍：同一次故障只报一回，好了再坏再报
                if !failing { fail(error) }
                failing = true
            }
            try? await Task.sleep(for: Self.liveScan)
        }
    }

    func liveOwners() async throws -> [String: LiveServers.Owner] {
        var owners = try await services.store.liveOwners(hosts: Self.liveHosts(services))
        for (sessionID, owner) in owners where owner.directory?.isEmpty != false {
            owners[sessionID]?.directory = services.bridge.session(sessionID: sessionID)?.cwd.path
        }
        return owners
    }

    func scanLive(only sessionIDs: Set<String>? = nil) async throws {
        let before = liveScanning
        let scan = Task {
            _ = await before?.result
            try await self.scanLiveNow(only: sessionIDs)
        }
        liveScanning = scan
        try await scan.value
    }

    private func scanLiveNow(only sessionIDs: Set<String>?) async throws {
        let owners = try await liveOwners()
        var scanner = liveScanner
        let found = await scanner.find(for: owners, only: sessionIDs).reduce(into: [UUID: [URL]]()) { $0[SessionState.recordID(sessionID: $1.key)] = $1.value }
        liveScanner = scanner
        livePreviews.found(found, scanned: sessionIDs.map { Set($0.map(SessionState.recordID(sessionID:))) })
    }

    /// 2 秒：服务起来到钮出现等得住。实测本机约 1,600 个进程时一遍 10 个会话中位 3.7 ms、50 个 4.7 ms，大头是读全部监听口，不随会话数涨。
    static let liveScan = Duration.seconds(2)
}
#endif
