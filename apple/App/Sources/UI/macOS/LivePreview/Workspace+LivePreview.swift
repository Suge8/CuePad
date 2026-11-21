#if os(macOS)
import CueStore
import Observation
import SwiftUI
import WebKit

extension Workspace {
    /// 会话页栏头那颗钮与菜单里的"打开活预览"：最左那个会话的活预览开在它紧右边、再点收起（放满了挤掉最右那块）。第一次打开时给这个会话建一份；
    /// 先用 Agent 发来的（`cuepad live`），再用你填过的，没有或认出的那个已不在了才换认出的服务里最近起来的，都没有是空的地址输入。
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

    /// 这个会话可看的页面，点开时开的在前：Agent 发来的（`cuepad live`）、你填过还开着的、认出的服务（最近起来的在前）。按认出的地址开过、服务已不在的不算。
    /// "有没有页面可看"只此一处：会话条的标、栏头的钮、答手机（`answerLivePhones`）都从它起。
    func livePages(_ session: UUID) -> [URL] {
        let found = liveFound[session] ?? []
        let kept = livePreviews[session].flatMap { $0.keeps(found) ? $0.address : nil }
        var pages: [URL] = []
        for url in [liveSent[session]?.url, kept].compactMap(\.self) + found where !pages.contains(url) { pages.append(url) }
        return pages
    }

    func hasLivePage(_ session: UUID) -> Bool { !livePages(session).isEmpty }

    func showsLivePreview(_ session: UUID) -> Bool { beside.contains(.preview) && self.session(in: .main)?.id == session }

    /// nil：没有页面可看、预览也没开着，栏头不放这颗钮（手动打开在会话的菜单里，`openLivePreview`）。开着空的地址输入也有它：收起只有这一处。
    func liveButton(_ session: UUID) -> LiveButton? {
        if showsLivePreview(session) { return .open(livePreviews[session]?.address) }
        guard let first = livePages(session).first else { return nil }
        return .closed(first)
    }

    /// 会话的菜单里的"打开活预览"（只在这个会话还没有页面可看、栏头没有那颗钮时有）：会话放到主区，右半滑开空的地址输入。
    /// 手机要用 UU 远程看时（`showLive`）也走这里，那时有页面可看，开的是它。
    func openLivePreview(_ session: SessionState) {
        if self.session(in: .main)?.id != session.id { openSession(session.id, sessionID: session.sessionID, in: .main) }
        if !beside.contains(.preview) { toggleLivePreview() }
    }

    /// 活预览只看这台 Mac 上的会话（本机的服务、本机的 localhost）。
    func livesHere(_ session: SessionState) -> Bool { Self.liveHosts(services).contains(session.hostID) }

    static func liveHosts(_ services: AppServices) -> [String] { [services.hostID] + DebugHooks.liveHosts }

    /// Agent 发来的地址（`cuepad live`）。
    func followLiveAddresses() async {
        do {
            for try await addresses in services.store.observe({ try $0.liveAddresses() }) { take(addresses) }
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    /// 收下还没收过的那几条：订阅到的，与 Agent 的动作赶在订阅之前来时当场读的（`answerLive`）走这一处，同一条不收两遍。
    /// App 起来之前发的不算（那时的服务多半已经不在了）。
    func take(_ addresses: [LiveAddress]) {
        let start = LiveServers.launched() ?? .now
        for address in addresses where address.sentAt > liveTaken[address.sessionID]?.sentAt ?? start {
            liveTaken[address.sessionID] = address
            receive(address)
        }
    }

    /// 记到会话上，并在后台为它建好预览、载入这一页：之后 Agent 的 `cuepad live snapshot` 等作用在这一页上，用户点开看到的也是它。
    /// 会话此刻在主区最左、旁边空着就直接滑开，否则只让栏头那颗钮亮起，不动排布。
    private func receive(_ address: LiveAddress) {
        let id = SessionState.recordID(sessionID: address.sessionID)
        let target = LivePreview.Target(url: address.url, source: address.found ? .found : .sent)
        let here = session(in: .main)?.id == id
        let preview = livePreviews[id] ?? LivePreview()
        preview.sessionID = address.sessionID
        livePreviews[id] = preview
        liveReleased.remove(id)
        // Agent 这期间操作的是你开着的这一页
        if !preview.yields(showing: here && beside.contains(.preview)) { return liveSent[id] = target }
        liveSent[id] = nil
        preview.retarget(target)
        preview.start()
        preview.engage()
        if here, beside.isEmpty { toggleLivePreview() }
    }

    /// 每隔 `liveScan` 扫一遍本机进程表，把在监听、答得出网页的口归给会话：窗口有人看着时（`ViewerKeeper.present`）扫本机全部没结束的会话
    /// （栏头的钮与会话条的标都读它），只有手机、iPad 看着时只扫它们开着的那几个（`livePhones`），都没有就不扫、等有了再起。扫完答手机（`answerLivePhones`）。
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

    /// 本机没结束的会话各自的进程与工作目录（`LiveServers` 认服务归属用）；库里还没有工作目录的用桥报的。
    func liveOwners() async -> [String: LiveServers.Owner] {
        var owners = (try? await services.store.liveOwners(hosts: Self.liveHosts(services))) ?? [:]
        for (sessionID, owner) in owners where owner.directory?.isEmpty != false {
            owners[sessionID]?.directory = services.bridge.session(sessionID: sessionID)?.cwd.path
        }
        return owners
    }

    /// 扫一遍（`only` 给了只要这几个会话的），一遍一遍排着来：收到手机一问时的那一遍与按节奏的这一遍交叠的话，后写回的会盖掉先写回的那一遍问到的，
    /// 隧道放行哪些口读的就是它（`livePorts`）。
    func scanLive(only sessionIDs: Set<String>? = nil) async {
        let before = liveScanning
        let scan = Task {
            await before?.value
            await self.scanLiveNow(only: sessionIDs)
        }
        liveScanning = scan
        await scan.value
    }

    /// 开着的预览跟着它：按认出的地址开的，地址不在了、又认出了别的（5173 被占换到 5174）就跟过去；空着地址的，认出了就载入。
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

    /// 预览栏上的点选钮：开着就收，没开就开；点中的元素挂进左边会话的回复框（`ReplyNote.Element`），回复框接过焦点，接着写那一句。
    /// 放大着的先放回右半：回复框被盖在下面。
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
