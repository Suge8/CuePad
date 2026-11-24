#if os(macOS)
import CueStore
import Observation
import SwiftUI
import WebKit

extension Workspace {
    /// 没点名时说的是开着预览的那个会话，没有就是这一排最左的会话。
    var liveSession: SessionRoute? {
        guard case .wide(let state) = navigation else { return nil }
        return state.sessions.first { $0.id == state.preview } ?? state.sessions.first
    }

    func toggleLivePreview(of route: SessionRoute? = nil) {
        guard case .wide(var state) = navigation, let session = route ?? liveSession else { return }
        if state.preview != session.id {
            let preview = livePreviews[session.id] ?? LivePreview()
            preview.sessionID = preview.sessionID ?? session.sessionID
            livePreviews[session.id] = preview
            if let sent = liveSent.removeValue(forKey: session.id) {
                preview.retarget(sent)
            } else if let found = liveFound[session.id], let first = found.first, !preview.keeps(found) {
                preview.retarget(.init(url: first, source: .found))
            }
        }
        state.togglePreview(of: session.id, room: wideRoom)
        navigation = .wide(state)
    }

    func livePages(_ session: UUID) -> [URL] {
        let found = liveFound[session] ?? []
        let kept = livePreviews[session].flatMap { $0.keeps(found) ? $0.address : nil }
        var pages: [URL] = []
        for url in [liveSent[session]?.url, kept].compactMap(\.self) + found where !pages.contains(url) { pages.append(url) }
        return pages
    }

    func hasLivePage(_ session: UUID) -> Bool { !livePages(session).isEmpty }

    func showsLivePreview(_ session: UUID) -> Bool { panes.contains(.preview(session)) }

    func liveButton(_ session: UUID) -> LiveButton? {
        if showsLivePreview(session) { return .open(livePreviews[session]?.address) }
        guard let first = livePages(session).first else { return nil }
        return .closed(first)
    }

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
        let target = LivePreview.Target(url: url, source: found ? .found : .sent)
        let shown = LiveAddress.shown(url)
        liveTaken[sessionID] = .init(url: url, found: found, at: .now)
        let preview = livePreviews[id] ?? LivePreview()
        preview.sessionID = sessionID
        livePreviews[id] = preview
        liveReleased.remove(id)
        if !preview.yields(showing: showsLivePreview(id)) {
            liveSent[id] = target
            let typed = preview.address.map(LiveAddress.shown) ?? ""
            return .done("用户正开着这个会话的预览、看着他自己填的 \(typed)，没换掉：他收起再打开时换成 \(shown)。在那之前 cuepad live snapshot 等操作的是他那一页。")
        }
        liveSent[id] = nil
        preview.retarget(target)
        preview.start()
        preview.engage()
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
        let scanned = sessionIDs.map { Set($0.map(SessionState.recordID(sessionID:))) }
        var next = liveFound
        if let scanned { for id in scanned { next[id] = found[id] } } else { next = found }
        if liveFound != next { liveFound = next }
        for (id, preview) in livePreviews where scanned?.contains(id) ?? true {
            let urls = found[id] ?? []
            preview.serving = urls
            if let first = urls.first, !preview.keeps(urls) { preview.retarget(.init(url: first, source: .found)) }
        }
    }

    /// 2 秒：服务起来到钮出现等得住。实测本机约 1,600 个进程时一遍 10 个会话中位 3.7 ms、50 个 4.7 ms，大头是读全部监听口，不随会话数涨。
    static let liveScan = Duration.seconds(2)

    func pickElement() {
        guard let session = liveSession, let preview = livePreviews[session.id] else { return }
        if preview.picking { return preview.cancelPick() }
        Task {
            guard let element = await preview.pick() else { return }
            services.settings.quote(element, for: session.id)
            endLiveFill()
            replyFocus = session.id
        }
    }
}
#endif
