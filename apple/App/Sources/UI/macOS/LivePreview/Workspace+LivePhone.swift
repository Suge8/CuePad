#if os(macOS)
import CueStore
import Foundation

/// Mac 这头答手机、iPad（`LiveSignal`）：它们开着本机哪个会话的页，就答这个会话有哪些页面可看（规则与栏头的钮同一处，`livePages`），
/// 变了主动再答；它们开着那个会话的活预览时，另给一张票据与隧道口（`LiveTunnel.Server`），隧道只放这个会话名下的服务（`admitLive`）。
extension Workspace {
    struct LivePhone {
        struct Key: Hashable {
            let phone: VoiceEndpoint
            let sessionID: String
        }

        /// 回信用手机发来时的那一路（信令头里的 session）与它最近一问的 id。
        var channel: VoiceSessionID
        var request: UUID
        var until: ContinuousClock.Instant
        /// 开着预览时才有：只给这台手机、这个会话，手机走了、关了预览、过期就作废。
        var ticket: Data?
        /// 上一次答它的（变了才再答）。
        var answered: LiveSignal?
    }

    /// 直到所在任务取消（`follow`）。
    func followLivePhones() async {
        for await event in services.liveEvents.stream { await receiveLive(event) }
    }

    func receiveLive(_ event: VoiceRelayEvent) async {
        switch event {
        case .received(let received):
            if case .live(.show(_, let sessionID)) = received.payload { return await showLive(sessionID) }
            guard case .live(.watch(let request, let sessionID, let open)) = received.payload else { return }
            let key = LivePhone.Key(phone: received.header.sender, sessionID: sessionID)
            let fresh = livePhones[key] == nil
            var phone = livePhones[key] ?? LivePhone(channel: received.header.session, request: request, until: .now)
            phone.channel = received.header.session
            phone.request = request
            phone.until = .now + LiveSignal.lease
            if open, phone.ticket == nil { phone.ticket = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }) }
            if !open { phone.ticket = nil }
            phone.answered = nil  // 每一问都答：手机靠答复续着钮
            livePhones[key] = phone
            // 刚开始看的会话先扫一遍再答：第一句就是准的，不等下一轮
            if fresh { await scanLive(only: [sessionID]) }
            await answerLivePhones()
        case .peerClosed(let endpoint, _):
            livePhones = livePhones.filter { $0.key.phone != endpoint }
            syncLiveDoor()
        case .localClosed:
            // 本机这条中转连接换了：手机们会按新的租约再问
            livePhones = [:]
            syncLiveDoor()
        default: break
        }
    }

    /// 答过期的去掉，变了的（或还没答过的）答一次。扫完一轮（`watchLiveServers`）与收到一问时调。
    func answerLivePhones() async {
        let now = ContinuousClock.now
        livePhones = livePhones.filter { $0.value.until > now }
        syncLiveDoor()
        guard !livePhones.isEmpty else { return }
        let needsDoor = livePhones.values.contains { $0.ticket != nil }
        let port = needsDoor ? await openLiveDoor() : nil
        // 只答本机这几台上没结束的会话；别处的、结束了的答没有页面
        let hosted = Set(((try? await services.store.liveOwners(hosts: Self.liveHosts(services))) ?? [:]).keys)
        for (key, phone) in livePhones {
            let id = SessionState.recordID(sessionID: key.sessionID)
            let here = hosted.contains(key.sessionID)
            var door: LiveSignal.Door?
            if let ticket = phone.ticket, let port { door = LiveSignal.Door(addresses: LiveTunnel.localAddresses(), port: port, ticket: ticket) }
            let answer = LiveSignal.pages(request: phone.request, session: key.sessionID, pages: here ? livePages(id) : [], serving: here ? liveFound[id] ?? [] : [],
                                          sent: here ? liveTaken[key.sessionID] : nil, door: here ? door : nil)
            guard answer != phone.answered, livePhones[key] != nil else { continue }
            livePhones[key]?.answered = answer
            do {
                try await services.liveSignaling?.sendVoice(.live(signal: answer), session: phone.channel, to: key.phone)
            } catch {
                AppServices.log.notice("活预览答手机没发出去：\(String(describing: error), privacy: .public)")
            }
        }
    }

    /// 手机要用 UU 远程看这个会话（`LiveSignal.show`）：开到主区，有页面可看就同栏头的钮开活预览（地址照开合的规则，你填的不换），
    /// 窗口提到最前。只认本机这台上没结束的会话（同 `answerLivePhones`）。
    private func showLive(_ sessionID: String) async {
        let hosted = ((try? await services.store.liveOwners(hosts: Self.liveHosts(services))) ?? [:]).keys
        guard hosted.contains(sessionID), let state = try? await services.store.sessionState(sessionID) else { return }
        // 手机看着时只扫它看的会话：此刻认出的才准
        await scanLive(only: [sessionID])
        if hasLivePage(state.id) { openLivePreview(state) } else { openSession(state.id, sessionID: sessionID) }
        services.windowShell?.show()
    }

    /// 隧道口：开着就用它，没开就开（端口随机）；没取到门铃的密钥（中转还没连上过）开不了。
    private func openLiveDoor() async -> UInt16? {
        if let liveServer { return liveServer.port }
        if let starting = liveServerStarting { return await starting.value }
        guard let key = services.liveSignaling?.liveTunnelKey else { return nil }
        let starting = Task<UInt16?, Never> { [weak self] in
            do {
                let server = try LiveTunnel.Server(key: key) { [weak self] request in await self?.admitLive(request) ?? .refused }
                let port = try await server.start()
                self?.liveServer = (server, port)
                return port
            } catch {
                AppServices.log.error("活预览的隧道口开不了：\(String(describing: error), privacy: .public)")
                return nil
            }
        }
        liveServerStarting = starting
        let port = await starting.value
        liveServerStarting = nil
        return port
    }

    /// 作废了的票据连着的断掉；没有手机开着预览了就关隧道口：它只在有人要看时听。
    private func syncLiveDoor() {
        guard let liveServer else { return }
        let tickets = Set(livePhones.values.compactMap(\.ticket))
        guard tickets.isEmpty else { return liveServer.server.keep(tickets) }
        liveServer.server.cancel()
        self.liveServer = nil
        livePorts = [:]
    }

    /// 隧道的一条连接放不放（`LiveTunnel.Server`）：票据要是这台 Mac 发给开着预览的手机、还没过期的；端口 0 只验票。
    /// 目标要是本机（回环、本机的局域网地址），端口要属于这个会话：它名下在监听的（答不答网页都算），或它的页面地址里的（Agent 发来、你填的）。
    func admitLive(_ request: LiveTunnel.Request) async -> LiveTunnel.Server.Admission {
        guard let (key, _) = livePhones.first(where: { $0.value.ticket == request.ticket && $0.value.until > .now }) else { return .ticket }
        guard request.port != 0 else { return .probe }
        var host = request.host.lowercased()
        if host.hasPrefix("[") { host = String(host.dropFirst().dropLast()) }
        guard LiveTunnel.Proxy.isMac(host, addresses: Set(LiveTunnel.localAddresses().map(\.host))) else { return .refused }
        guard await livePorts(key.sessionID).contains(Int(request.port)) else { return .refused }
        // *.localhost 系统的解析器不一定认（浏览器认），一律连回环；Host 头随字节原样到服务
        return .open(host: host.hasSuffix(".localhost") ? "localhost" : host, port: request.port)
    }

    private func livePorts(_ sessionID: String) async -> Set<Int> {
        if let kept = livePorts[sessionID], ContinuousClock.now - kept.at < .seconds(1) { return kept.ports }
        var owner = (try? await services.store.liveOwner(sessionID)) ?? LiveServers.Owner(process: nil, directory: nil)
        if owner.directory?.isEmpty != false { owner.directory = services.bridge.session(sessionID: sessionID)?.cwd.path }
        var ports = await LiveServers.ports(for: [sessionID: owner])[sessionID] ?? []
        let local = Set(LiveTunnel.localAddresses().map(\.host))
        for url in livePages(SessionState.recordID(sessionID: sessionID)) {
            guard let port = url.port, let host = url.host(percentEncoded: false), LiveTunnel.Proxy.isMac(host, addresses: local) else { continue }
            ports.insert(port)
        }
        livePorts[sessionID] = (ports, .now)
        return ports
    }
}
#endif
