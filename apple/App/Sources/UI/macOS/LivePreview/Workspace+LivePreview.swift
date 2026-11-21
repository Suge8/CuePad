#if os(macOS)
import CueStore
import Observation
import SwiftUI
import WebKit

extension Workspace {
    func toggleLivePreview() {
        guard case .wide(var state) = navigation, !state.home, case .session(let session) = state.main else { return }
        if !state.beside.contains(.preview) {
            let preview = livePreviews[session.id] ?? LivePreview()
            preview.sessionID = preview.sessionID ?? session.sessionID
            livePreviews[session.id] = preview
            if let sent = liveSent.removeValue(forKey: session.id) {
                preview.retarget(sent)
            } else if let found = liveFound[session.id], let first = found.first, !preview.keeps(found) {
                preview.retarget(.init(url: first, source: .found))
            }
        }
        state.togglePreview(room: wideRoom)
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

    func showsLivePreview(_ session: UUID) -> Bool { beside.contains(.preview) && self.session(in: .main)?.id == session }

    func liveButton(_ session: UUID) -> LiveButton? {
        if showsLivePreview(session) { return .open(livePreviews[session]?.address) }
        guard let first = livePages(session).first else { return nil }
        return .closed(first)
    }

    func openLivePreview(_ session: SessionState) {
        if self.session(in: .main)?.id != session.id { openSession(session.id, sessionID: session.sessionID, in: .main) }
        if !beside.contains(.preview) { toggleLivePreview() }
    }

    func livesHere(_ session: SessionState) -> Bool { Self.liveHosts(services).contains(session.hostID) }

    static func liveHosts(_ services: AppServices) -> [String] { [services.hostID] + DebugHooks.liveHosts }

    func followLiveAddresses() async {
        do {
            for try await addresses in services.store.observe({ try $0.liveAddresses() }) { take(addresses) }
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    func take(_ addresses: [LiveAddress]) {
        let start = LiveServers.launched() ?? .now
        for address in addresses where address.sentAt > liveTaken[address.sessionID]?.sentAt ?? start {
            liveTaken[address.sessionID] = address
            receive(address)
        }
    }

    private func receive(_ address: LiveAddress) {
        let id = SessionState.recordID(sessionID: address.sessionID)
        let target = LivePreview.Target(url: address.url, source: address.found ? .found : .sent)
        let here = session(in: .main)?.id == id
        let preview = livePreviews[id] ?? LivePreview()
        preview.sessionID = address.sessionID
        livePreviews[id] = preview
        liveReleased.remove(id)
        if !preview.yields(showing: here && beside.contains(.preview)) { return liveSent[id] = target }
        liveSent[id] = nil
        preview.retarget(target)
        preview.start()
        preview.engage()
        if here, beside.isEmpty { toggleLivePreview() }
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
        guard let session = session(in: .main), let preview = livePreviews[session.id] else { return }
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
