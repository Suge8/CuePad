import Foundation

extension VoiceService {
    func loadRequests(after cursor: VoicePageCursor?) async throws -> VoicePage<VoiceCallProjection.Request> {
        #if os(iOS)
        return try await requestPages.load(after: cursor, read: requestSnapshot)
        #else
        return try await requestSnapshot(cursor).page
        #endif
    }

    func loadReplies(after cursor: VoicePageCursor?) async throws -> VoicePage<VoiceCallProjection.Reply> {
        #if os(iOS)
        return try await replyPages.load(after: cursor, read: replySnapshot)
        #else
        return try await replySnapshot(cursor).page
        #endif
    }

    func loadExecutions(after cursor: VoicePageCursor?) async throws -> VoicePage<VoiceExecutionTarget> {
        #if os(iOS)
        return try await executionPages.load(after: cursor, read: executionSnapshot)
        #else
        return try await executionSnapshot(cursor).page
        #endif
    }

    private func requestSnapshot(_ cursor: VoicePageCursor?) async throws -> VoicePageSnapshot<VoiceCallProjection.Request> {
        try await snapshot(.requests, cursor: cursor) { if case .requests(let page) = $0 { page } else { nil } }
    }

    private func replySnapshot(_ cursor: VoicePageCursor?) async throws -> VoicePageSnapshot<VoiceCallProjection.Reply> {
        try await snapshot(.replies, cursor: cursor) { if case .replies(let page) = $0 { page } else { nil } }
    }

    private func executionSnapshot(_ cursor: VoicePageCursor?) async throws -> VoicePageSnapshot<VoiceExecutionTarget> {
        try await snapshot(.executions, cursor: cursor) { if case .executions(let page) = $0 { page } else { nil } }
    }

    private func snapshot<Row>(_ list: VoicePageList, cursor: VoicePageCursor?,
                               extract: (VoicePageResult.Content) -> VoicePage<Row>?) async throws -> VoicePageSnapshot<Row> {
        let originalSession = session
        let result = try await readPage(list, cursor: cursor)
        guard session == originalSession, result.session == originalSession else { throw VoicePageError.sessionUnavailable }
        if case .failed(let error) = result.content { throw error }
        guard let page = extract(result.content) else { throw VoiceSignalError.invalid }
        return .init(page: page, version: result.version)
    }

    #if os(iOS)
    /// 撤销的是远端投影来源，不是只把一份展示数组清空；旧租约迟到的首页不能重新取得操作入口。
    func revokeProjection(local: VoiceEndpoint? = nil, peer: VoiceEndpoint? = nil) {
        guard local == nil || phoneBinding?.local == local, peer == nil || phoneBinding?.peer == peer else { return }
        phoneBinding = nil
        executionPages.disconnected()
    }

    func updatePages(_ value: VoiceCallProjection?) {
        guard let value else {
            requestPages.reset(); replyPages.reset(); executionPages.reset()
            return
        }
        requestPages.receive(.init(items: value.requests, nextCursor: value.pages.requests.nextCursor), session: value.session,
                             version: value.pages.requests.version, read: requestSnapshot)
        replyPages.receive(.init(items: value.replies, nextCursor: value.pages.replies.nextCursor), session: value.session,
                           version: value.pages.replies.version, read: replySnapshot)
        executionPages.receive(.init(items: value.executions, nextCursor: value.pages.executions.nextCursor), session: value.session,
                               version: value.pages.executions.version, read: executionSnapshot)
    }
    #endif
}
