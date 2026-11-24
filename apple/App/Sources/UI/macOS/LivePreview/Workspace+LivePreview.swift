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

    /// Agent 交来的地址（`cuepad live`、`live app`、`live sim`）：后台照开着的载入，照此刻的排布滑开或只亮钮，回执说的是实际是哪一种。
    func openLive(_ sessionID: String, url: URL, found: Bool) async throws -> LiveChannel.Reply {
        let id = SessionState.recordID(sessionID: sessionID)
        let here = try await services.store.sessionState(sessionID).map(livesHere) ?? false
        let shown = LiveAddress.shown(url)
        switch livePreviews.receive(.init(url: url, found: found, at: .now), for: id, sessionID: sessionID, showing: showsLivePreview(id)) {
        case .held(let typed):
            return .done("用户正开着这个会话的预览、看着他自己填的 \(LiveAddress.shown(typed))，没换掉：他收起再打开时换成 \(shown)。在那之前 cuepad live snapshot 等操作的是他那一页。")
        case .loaded(let preview):
            preview.start()
            preview.engage()
        }
        if session(in: .main)?.id == id, !isSplit { toggleLivePreview() }
        if showsLivePreview(id) { return .done("已在这台 Mac 的 CuePad 里打开 \(shown)：会话开在主区，预览滑开了。") }
        guard here else { return .done("已交给这台 Mac 上的 CuePad：\(shown)。这个会话不在这台 Mac 的 CuePad 里，用户看不到这一页；页面在后台载着，你照样能操作它。") }
        return .done("已交给这台 Mac 上的 CuePad：\(shown)。会话没开在主区（或右半开着别的），会话栏头的预览钮亮起、等用户点开；页面在后台载着。")
    }

    func watchLiveServers() async {
        while !Task.isCancelled {
            let everyone = services.viewer.present
            let phones = Set(livePhones.keys.map(\.sessionID))
            guard everyone || !phones.isEmpty else {
                for await busy in Observations({ self.services.viewer.present || !self.livePhones.isEmpty }) where busy { break }
                continue
            }
            await scanLive(only: everyone ? nil : phones)
            await answerLivePhones()
            try? await Task.sleep(for: Self.liveScan)
        }
    }

    func liveOwners() async -> [String: LiveServers.Owner] {
        var owners = (try? await services.store.liveOwners(hosts: Self.liveHosts(services))) ?? [:]
        for (sessionID, owner) in owners where owner.directory?.isEmpty != false {
            owners[sessionID]?.directory = services.bridge.session(sessionID: sessionID)?.cwd.path
        }
        return owners
    }

    func scanLive(only sessionIDs: Set<String>? = nil) async {
        let before = liveScanning
        let scan = Task {
            await before?.value
            await self.scanLiveNow(only: sessionIDs)
        }
        liveScanning = scan
        await scan.value
    }

    private func scanLiveNow(only sessionIDs: Set<String>?) async {
        let owners = await liveOwners()
        var scanner = liveScanner
        let found = await scanner.find(for: owners, only: sessionIDs).reduce(into: [UUID: [URL]]()) { $0[SessionState.recordID(sessionID: $1.key)] = $1.value }
        liveScanner = scanner
        livePreviews.found(found, scanned: sessionIDs.map { Set($0.map(SessionState.recordID(sessionID:))) })
    }

    /// 2 秒：服务起来到钮出现等得住。实测本机约 1,600 个进程时一遍 10 个会话中位 3.7 ms、50 个 4.7 ms，大头是读全部监听口，不随会话数涨。
    static let liveScan = Duration.seconds(2)
}
#endif
