#if os(macOS)
import CueStore
import Observation
import SwiftUI
import WebKit

extension Workspace {
    /// 会话页栏头那颗钮与菜单里的"打开活预览"：左边那个会话的活预览在右半开、收（开着并排的会话时换掉它）。第一次打开时给这个会话建一份；
    /// 先用 Agent 发来的（`cuepad live`），再用你填过的，没有或认出的那个已不在了才换认出的服务里最近起来的，都没有是空的地址输入。
    func toggleLivePreview() {
        guard case .wide(var state) = navigation, !state.home, case .session(let session) = state.main else { return }
        if state.beside == .preview {
            state.beside = nil
        } else {
            let preview = livePreviews[session.id] ?? LivePreview()
            preview.sessionID = preview.sessionID ?? session.sessionID
            livePreviews[session.id] = preview
            if let sent = liveSent.removeValue(forKey: session.id) {
                preview.retarget(sent)
            } else if let found = liveFound[session.id], let first = found.first, !Self.keeps(preview, found) {
                preview.retarget(.init(url: first, source: .found))
            }
            state.beside = .preview
        }
        navigation = .wide(state)
    }

    /// 有地址、而且不是认出过又不在了的（认出的地址只认 `liveFound`）。
    private static func keeps(_ preview: LivePreview, _ found: [URL]) -> Bool {
        guard let address = preview.address else { return false }
        return preview.source != .found || found.contains(address)
    }

    /// 这个会话有没有页面可看（会话条那一行带不带标，栏头那颗预览钮在不在也从它起）：认出了它的服务、Agent 发来过地址（`cuepad live`）、
    /// 你给它填过地址。按认出的地址开过、服务已不在的不算。
    func hasLivePage(_ session: UUID) -> Bool {
        liveFound[session]?.isEmpty == false || liveSent[session] != nil || livePreviews[session].map { Self.keeps($0, []) } ?? false
    }

    func showsLivePreview(_ session: UUID) -> Bool { beside == .preview && self.session(in: .main)?.id == session }

    enum LiveButton: Equatable {
        /// 点开就是这个地址；nil 是空的地址输入。
        case closed(URL?)
        case open(URL?)

        var isShowing: Bool { if case .open = self { true } else { false } }
    }

    /// nil：没有页面可看、预览也没开着，栏头不放这颗钮（手动打开在会话的菜单里，`openLivePreview`）。开着空的地址输入也有它：收起只有这一处。
    func liveButton(_ session: UUID) -> LiveButton? {
        if showsLivePreview(session) { return .open(livePreviews[session]?.address) }
        guard hasLivePage(session) else { return nil }
        let found = liveFound[session] ?? []
        let kept = livePreviews[session].flatMap { Self.keeps($0, found) ? $0.address : nil }
        return .closed(liveSent[session]?.url ?? kept ?? found.first)
    }

    /// 会话的菜单里的"打开活预览"（只在这个会话还没有页面可看、栏头没有那颗钮时有）：会话放到主区，右半滑开空的地址输入。
    func openLivePreview(_ session: SessionState) {
        if self.session(in: .main)?.id != session.id { openSession(session.id, sessionID: session.sessionID, in: .main) }
        if beside != .preview { toggleLivePreview() }
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
        for address in addresses where address.sentAt > liveTaken[address.sessionID] ?? start {
            liveTaken[address.sessionID] = address.sentAt
            receive(address)
        }
    }

    /// 记到会话上，并在后台为它建好预览、载入这一页：之后 Agent 的 `cuepad live snapshot` 等作用在这一页上，用户点开看到的也是它。
    /// 会话此刻在主区、右半空着就直接滑开，否则只让栏头那颗钮亮起，不动排布。
    private func receive(_ address: LiveAddress) {
        let id = SessionState.recordID(sessionID: address.sessionID)
        let target = LivePreview.Target(url: address.url, source: address.found ? .found : .sent)
        let here = session(in: .main)?.id == id
        let preview = livePreviews[id] ?? LivePreview()
        preview.sessionID = address.sessionID
        livePreviews[id] = preview
        liveReleased.remove(id)
        // 你输入的、此刻正开着的地址不被顶掉：这一条留到下次打开，Agent 这期间操作的是你开着的这一页
        if here, beside == .preview, preview.address != nil, preview.source == .typed { return liveSent[id] = target }
        liveSent[id] = nil
        preview.retarget(target)
        preview.start()
        preview.engage()
        if here, beside == nil { toggleLivePreview() }
    }

    /// 窗口有人看着时（`ViewerKeeper.present`，`MainWindow` 挂着）每隔 `liveScan` 扫一遍本机进程表，把在监听、答得出网页的口归给本机没结束的各个会话：
    /// 栏头的预览钮与会话条的标都读它。扫一遍的开销不随会话多少变（`LiveServers.find`）。
    /// 开着的预览跟着它：按认出的地址开的，地址不在了、又认出了别的（5173 被占换到 5174）就跟过去；空着地址的，认出了就载入。
    func watchLiveServers() async {
        var servers = LiveServers()
        while !Task.isCancelled {
            var owners = (try? await services.store.liveOwners(hosts: Self.liveHosts(services))) ?? [:]
            for (sessionID, owner) in owners where owner.directory?.isEmpty != false {
                owners[sessionID]?.directory = services.bridge.session(sessionID: sessionID)?.cwd.path
            }
            let found = await servers.find(for: owners).reduce(into: [UUID: [URL]]()) { $0[SessionState.recordID(sessionID: $1.key)] = $1.value }
            if liveFound != found { liveFound = found }
            for (id, preview) in livePreviews {
                let urls = found[id] ?? []
                preview.serving = urls
                if let first = urls.first, !Self.keeps(preview, urls) { preview.retarget(.init(url: first, source: .found)) }
            }
            try? await Task.sleep(for: Self.liveScan)
        }
    }

    /// 2 秒：服务起来到钮出现等得住。实测本机约 1,600 个进程时一遍 10 个会话中位 3.7 ms、50 个 4.7 ms，大头是读全部监听口，不随会话数涨。
    static let liveScan = Duration.seconds(2)

    /// 预览栏上的点选钮：开着就收，没开就开；点中的元素挂进左边会话的回复框（`ReplyNote.Element`），回复框接过焦点，接着写那一句。
    func pickElement() {
        guard let session = session(in: .main), let preview = livePreviews[session.id] else { return }
        if preview.picking { return preview.cancelPick() }
        Task {
            guard let element = await preview.pick() else { return }
            services.settings.quote(element, for: session.id)
            replyFocus = session.id
        }
    }
}
#endif
