import Foundation
import os

extension VoiceService {
    /// 读请求没有业务幂等缓存，不重发、不跨租约续等；媒体结束不取消这层等待。
    func readPage(_ list: VoicePageList, cursor: VoicePageCursor?) async throws -> VoicePageResult {
        guard let session else { throw VoicePageError.refreshRequired }
        let query = VoicePageQuery(id: .init(UUID()), list: list, cursor: cursor)
        #if os(macOS)
        return makePage(query, session: session)
        #else
        guard let signaling, case .ready(let local) = signaling.voiceAvailability else { throw VoicePageError.unavailable }
        let scope = VoiceOperationScope()
        defer { scope.end(); pageReads[query.id] = nil }
        return try await scope.perform(within: .seconds(15)) {
            guard let host = try await self.services.store.cueProfile()?.activeHost else { throw VoicePageError.unavailable }
            let peer = try await signaling.resolveVoicePeer(VoiceDeviceID(host))
            guard signaling.voiceAvailability == .ready(endpoint: local), self.session == session else { throw VoicePageError.refreshRequired }
            return try await scope.wait { finish in
                self.pageReads[query.id] = Pending(session: session, peer: peer, local: local, finish: finish)
                scope.spawn {
                    do { try await signaling.sendVoice(.pageQuery(query: query), session: session, to: peer) }
                    catch { finish(.failure(error)) }
                }
            }
        }
        #endif
    }

    func receivePageResult(_ result: VoicePageResult, header: VoiceSignalHeader) {
        guard let wait = pageReads[result.query], wait.session == header.session, result.session == header.session,
              wait.peer == header.sender, wait.local == header.recipient else { return }
        pageReads[result.query] = nil
        #if os(iOS)
        if phone == nil, session == result.session {
            phoneBinding = (result.session, header.recipient, header.sender)
        }
        #endif
        wait.finish(.success(result))
    }

    func failPageReads(local: VoiceEndpoint? = nil, peer: VoiceEndpoint? = nil) {
        for (id, wait) in pageReads where (local == nil || wait.local == local) && (peer == nil || wait.peer == peer) {
            pageReads[id] = nil
            wait.finish(.failure(VoicePageError.unavailable))
        }
    }

    #if os(macOS)
    /// 只读仍保留的原对象；不依赖 remote 媒体 owner 存活。原通话已被另一轮替换时明确要求刷新。
    func makePage(_ query: VoicePageQuery, session: VoiceSessionID) -> VoicePageResult {
        do {
            guard let call, VoiceSessionID(call.session) == session else { throw VoicePageError.refreshRequired }
            return try fullProjection(call).pageResult(query)
        } catch {
            return .init(query: query.id, session: session, version: Data(), content: .failed(error as? VoicePageError ?? .storageUnavailable))
        }
    }

    func receivePageQuery(_ query: VoicePageQuery, header: VoiceSignalHeader) {
        if call.map({ VoiceSessionID($0.session) }) == header.session { projectionReaders[header.sender.device] = header }
        let result = makePage(query, session: header.session)
        Task {
            let scope = VoiceOperationScope()
            defer { scope.end() }
            do {
                guard let signaling else { throw VoicePageError.unavailable }
                try await scope.perform(within: .seconds(2)) {
                    try await signaling.sendVoice(.pageResult(result: result), session: header.session, to: header.sender)
                }
            } catch { AppServices.log.error("Voice page could not be delivered: \(String(describing: error))") }
        }
    }
    #endif
}
