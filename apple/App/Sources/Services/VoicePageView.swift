#if os(iOS)
import Foundation
import Observation

/// 每类只保留当前展示页，不累计历史、不复刻业务状态。按原锚点刷新整页，无追加去重队列。
/// 首页阶段变化不动历史页；该类内容变更才刷新。停止目标在版本变化或断连时立即撤下。
@Observable final class VoicePageView<Row: Equatable & Codable & Sendable> {
    private(set) var page = VoicePage<Row>(items: [], nextCursor: nil)
    private(set) var loading = false
    private(set) var error: VoicePageError?
    @ObservationIgnored private var session: VoiceSessionID?
    @ObservationIgnored private var version: Data?
    private enum Selection { case pushedHead, selected(VoicePageCursor?) }
    @ObservationIgnored private var selection = Selection.pushedHead
    @ObservationIgnored private var operation: Task<VoicePage<Row>, Error>?
    @ObservationIgnored private var ticket: UUID?

    var canReturnToHead: Bool {
        switch selection {
        case .pushedHead: false
        case .selected(let cursor): cursor?.after != nil
        }
    }

    isolated deinit { operation?.cancel() }

    func reset() {
        operation?.cancel()
        operation = nil
        ticket = nil
        session = nil
        version = nil
        selection = .pushedHead
        page = .init(items: [], nextCursor: nil)
        loading = false
        error = nil
    }

    func disconnected(clear: Bool) {
        operation?.cancel()
        ticket = nil
        version = nil
        loading = false
        error = .unavailable
        if clear { page = .init(items: [], nextCursor: page.nextCursor) }
    }

    func receive(_ first: VoicePage<Row>, session: VoiceSessionID, version: Data, clearStale: Bool,
                 read: @escaping (VoicePageCursor?) async throws -> VoicePageSnapshot<Row>) {
        if self.session != session { reset(); self.session = session }
        guard self.version != version else { return }
        self.version = version
        switch selection {
        case .pushedHead:
            operation?.cancel()
            ticket = nil
            page = first
            loading = false
            error = nil
        case .selected(let cursor):
            if clearStale { page = .init(items: [], nextCursor: page.nextCursor) }
            _ = begin(after: cursor, read: read)
        }
    }

    func load(after cursor: VoicePageCursor?, read: @escaping (VoicePageCursor?) async throws -> VoicePageSnapshot<Row>) async throws -> VoicePage<Row> {
        let task = begin(after: cursor, read: read)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func begin(after cursor: VoicePageCursor?, read: @escaping (VoicePageCursor?) async throws -> VoicePageSnapshot<Row>) -> Task<VoicePage<Row>, Error> {
        operation?.cancel()
        selection = .selected(cursor)
        loading = true
        error = nil
        let id = UUID()
        ticket = id
        let task = Task {
            do {
                let result = try await read(cursor)
                try Task.checkCancellation()
                guard ticket == id else { throw CancellationError() }
                page = result.page
                version = result.version
                loading = false
                return page
            } catch {
                if ticket == id {
                    loading = false
                    self.error = error as? VoicePageError ?? .unavailable
                    if self.error == .refreshRequired || self.error == .sessionUnavailable { page = .init(items: [], nextCursor: nil) }
                }
                throw error
            }
        }
        operation = task
        return task
    }
}
#endif
