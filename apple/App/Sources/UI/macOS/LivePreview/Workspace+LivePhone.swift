#if os(macOS)
import CueStore
import Foundation

extension Workspace {
    struct LivePhone {
        struct Key: Hashable {
            let phone: VoiceEndpoint
            let sessionID: String
        }

        var channel: VoiceSessionID
        var request: UUID
        var until: ContinuousClock.Instant
        var ticket: Data?
        var answered: LiveSignal?
    }

    func followLivePhones() async {
        for await event in services.liveEvents.stream {
            do { try await receiveLive(event) } catch { fail(error) }
        }
    }

    func receiveLive(_ event: VoiceRelayEvent) async throws {
        switch event {
        case .received(let received):
            if case .live(.show(_, let sessionID)) = received.payload { return try await showLive(sessionID) }
            if case .live(.back(_, let sessionID)) = received.payload {
                return endRemoteFill(SessionState.recordID(sessionID: sessionID))
            }
            guard case .live(.watch(let request, let sessionID, let open)) = received.payload else { return }
            let key = LivePhone.Key(phone: received.header.sender, sessionID: sessionID)
            let fresh = livePhones[key] == nil
            var phone = livePhones[key] ?? LivePhone(channel: received.header.session, request: request, until: .now)
            phone.channel = received.header.session
            phone.request = request
            phone.until = .now + LiveSignal.lease
            if open, phone.ticket == nil { phone.ticket = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }) }
            if !open { phone.ticket = nil }
            phone.answered = nil
            livePhones[key] = phone
            if fresh { try await scanLive(only: [sessionID]) }
            try await answerLivePhones()
        case .peerClosed(let endpoint, _):
            livePhones = livePhones.filter { $0.key.phone != endpoint }
        case .localClosed:
            livePhones = [:]
        default: break
        }
    }

    func answerLivePhones() async throws {
        let now = ContinuousClock.now
        livePhones = livePhones.filter { $0.value.until > now }
        guard !livePhones.isEmpty else { return }
        let needsDoor = livePhones.values.contains { $0.ticket != nil }
        let port = needsDoor ? await openLiveDoor() : nil
        let hosted = Set(try await services.store.liveOwners(hosts: Self.liveHosts(services)).keys)
        for (key, phone) in livePhones {
            let id = SessionState.recordID(sessionID: key.sessionID)
            let here = hosted.contains(key.sessionID)
            var door: LiveSignal.Door?
            if let ticket = phone.ticket {
                let allowed = here ? try await livePorts(key.sessionID) : [:]
                liveServer?.server.limit(ticket, to: Set(allowed.keys.compactMap { UInt16(exactly: $0) }))
                if let port { door = LiveSignal.Door(entrance: .init(addresses: LiveTunnel.localAddresses(), port: port, ticket: ticket), ports: allowed.keys.sorted()) }
            }
            let answer = LiveSignal.pages(request: phone.request, session: key.sessionID, pages: here ? livePages(id) : [], serving: here ? livePreviews.entries[id]?.found ?? [] : [],
                                          sent: here ? livePreviews.entries[id]?.sent : nil, door: here ? door : nil)
            guard answer != phone.answered, livePhones[key] != nil else { continue }
            livePhones[key]?.answered = answer
            do {
                try await services.liveSignaling?.sendVoice(.live(signal: answer), session: phone.channel, to: key.phone)
            } catch {
                AppServices.log.notice("活预览答手机没发出去：\(String(describing: error), privacy: .public)")
            }
        }
    }

    private func showLive(_ sessionID: String) async throws {
        let hosted = try await services.store.liveOwners(hosts: Self.liveHosts(services)).keys
        guard hosted.contains(sessionID), let state = try await services.store.sessionState(sessionID) else { return }
        try await scanLive(only: [sessionID])
        let own = liveFill?.session == state.id && liveFill?.own == true
        liveFill = nil
        overlay = nil
        openSession(state.id, sessionID: sessionID)
        if hasLivePage(state.id) { openLivePreview(state) }
        services.windowShell?.show(overOthers: true)
        guard showsLivePreview(state.id) else { return services.windowShell?.restoreFrame() ?? () }
        liveFill = LiveFill(session: state.id, own: own, remote: true)
        services.windowShell?.fillScreen()
    }

    private func endRemoteFill(_ session: UUID) {
        guard let fill = liveFill, fill.remote, fill.session == session else { return }
        guard fill.own else { return endLiveFill() }
        liveFill?.remote = false
        services.windowShell?.restoreFrame()
    }

    private func openLiveDoor() async -> UInt16? {
        if let liveServer { return liveServer.port }
        if let starting = liveServerStarting { return await starting.value }
        guard let key = services.liveSignaling?.liveTunnelKey else { return nil }
        let starting = Task<UInt16?, Never> { [weak self] in
            do {
                let server = try LiveTunnel.Server(key: key) { [weak self] request in await self?.admitLive(request) ?? .refused }
                let port = try await server.start()
                self?.liveServer = (server, port)
                self?.syncLiveDoor()
                return self?.liveServer?.port
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

    /// 隧道口跟着开着预览的手机走（`livePhones` 一变就来）：没有票据就关上，起到一半的那个起好时也来这里核一遍。
    func syncLiveDoor() {
        guard let liveServer else { return }
        let tickets = Set(livePhones.values.compactMap(\.ticket))
        guard tickets.isEmpty else { return liveServer.server.keep(tickets) }
        liveServer.server.cancel()
        self.liveServer = nil
        livePorts = [:]
    }

    /// 隧道的一条连接放不放（`LiveTunnel.Server`）：票据要是这台 Mac 发给开着预览的手机、还没过期的；端口 0 只验票。
    /// 目标要是本机（回环、本机的局域网地址），端口要属于这个会话：它名下在监听、答 HTTP 的（页面与它调的接口），或它的页面地址里的（Agent 发来、你填的）。
    /// 连哪个地址由这头定（`livePorts`），不照手机写的：手机回环上照搬来的连接只说得出端口，而同一个端口号上 127.0.0.1 与 ::1 可以各是一个会话的服务。
    func admitLive(_ request: LiveTunnel.Request) async -> LiveTunnel.Server.Admission {
        guard let (key, _) = livePhones.first(where: { $0.value.ticket == request.ticket && $0.value.until > .now }) else { return .ticket }
        guard request.port != 0 else { return .probe }
        var host = request.host.lowercased()
        if host.hasPrefix("[") { host = String(host.dropFirst().dropLast()) }
        let target: String?
        do {
            target = LiveTunnel.Proxy.isMac(host, addresses: Set(LiveTunnel.localAddresses().map(\.host))) ? try await livePorts(key.sessionID)[Int(request.port)] : nil
        } catch {
            fail(error)
            return .refused
        }
        guard let target else {
            AppServices.log.notice("活预览的隧道没放行 \(host, privacy: .public):\(request.port)：不是这个会话的口")
            return .refused
        }
        return .open(host: target, port: request.port)
    }

    private func livePorts(_ sessionID: String) async throws -> [Int: String] {
        if let kept = livePorts[sessionID], ContinuousClock.now - kept.at < .seconds(1) { return kept.ports }
        var ports = try await liveScanner.ports(for: liveOwners(), only: [sessionID])[sessionID] ?? [:]
        let local = Set(LiveTunnel.localAddresses().map(\.host))
        for url in livePages(SessionState.recordID(sessionID: sessionID)) {
            guard let port = url.port, ports[port] == nil, let host = url.host(percentEncoded: false)?.lowercased(), LiveTunnel.Proxy.isMac(host, addresses: local) else { continue }
            // *.localhost 系统的解析器不一定认（浏览器认），一律连回环；Host 头随字节原样到服务
            ports[port] = host.hasSuffix(".localhost") ? "localhost" : host
        }
        livePorts[sessionID] = (ports, .now)
        return ports
    }
}
#endif
