import CryptoKit
import Foundation

extension VoiceCallProjection.RequestPreview {
    private static let maximumTextBytes = 512

    init(original: String) {
        var prefix = "", bytes = 0
        for character in original {
            let next = String(character)
            guard bytes + next.utf8.count <= Self.maximumTextBytes else { break }
            prefix.append(character)
            bytes += next.utf8.count
        }
        self.init(text: prefix, truncated: prefix != original)
    }
}

extension VoiceCallProjection {
    /// 三类各有独立配额，剩余空间不跨类抢占。单条超出首页配额时留下起始游标，用完整帧读取。
    /// 版本只由该类实际内容计算，阶段、朗读能力和另一类的变化均不会让当前页重排。
    private static let headLimit = VoiceSignalFormat.maximumPlaintextBytes / 4

    func bounded() throws -> Self {
        let query = VoiceCommand.ID(UUID())
        let requests = try page(self.requests, query: .init(id: query, list: .requests, cursor: nil), limit: Self.headLimit,
                                anchor: { .request($0.id) }, wrap: VoicePageResult.Content.requests)
        let replies = try page(self.replies, query: .init(id: query, list: .replies, cursor: nil), limit: Self.headLimit,
                               anchor: { .reply($0.message) }, wrap: VoicePageResult.Content.replies)
        let executions = try page(self.executions, query: .init(id: query, list: .executions, cursor: nil), limit: Self.headLimit,
                                  anchor: VoicePageAnchor.execution, wrap: VoicePageResult.Content.executions)
        let result = Self(session: session, phase: phase, requests: requests.page.items, replies: replies.page.items,
                          executions: executions.page.items, response: response,
                          omitted: .init(requests: self.requests.count - requests.page.items.count,
                                         replies: self.replies.count - replies.page.items.count,
                                         executions: self.executions.count - executions.page.items.count),
                          pages: .init(requests: .init(version: requests.version, nextCursor: requests.page.nextCursor),
                                       replies: .init(version: replies.version, nextCursor: replies.page.nextCursor),
                                       executions: .init(version: executions.version, nextCursor: executions.page.nextCursor)), canRepeat: canRepeat)
        guard try VoiceSignalFormat.canonicalJSON(VoiceSignalPayload.projection(value: result)).count <= VoiceSignalFormat.maximumPlaintextBytes else {
            throw VoicePageError.tooLarge
        }
        return result
    }

    func pageResult(_ query: VoicePageQuery) throws -> VoicePageResult {
        switch query.list {
        case .requests:
            let snapshot = try page(requests, query: query, anchor: { .request($0.id) }, wrap: VoicePageResult.Content.requests)
            return .init(query: query.id, session: session, version: snapshot.version, content: .requests(snapshot.page))
        case .replies:
            let snapshot = try page(replies, query: query, anchor: { .reply($0.message) }, wrap: VoicePageResult.Content.replies)
            return .init(query: query.id, session: session, version: snapshot.version, content: .replies(snapshot.page))
        case .executions:
            let snapshot = try page(executions, query: query, anchor: VoicePageAnchor.execution, wrap: VoicePageResult.Content.executions)
            return .init(query: query.id, session: session, version: snapshot.version, content: .executions(snapshot.page))
        }
    }

    private func page<Row>(
        _ rows: [Row], query: VoicePageQuery, limit: Int = VoiceSignalFormat.maximumPlaintextBytes,
        anchor: (Row) -> VoicePageAnchor, wrap: (VoicePage<Row>) -> VoicePageResult.Content
    ) throws -> VoicePageSnapshot<Row> {
        let ordered = Array(rows.reversed())
        var start = ordered.startIndex
        if let cursor = query.cursor {
            guard cursor.session == session else { throw VoicePageError.sessionUnavailable }
            guard cursor.list == query.list else { throw VoicePageError.refreshRequired }
            if let after = cursor.after {
                guard let index = ordered.firstIndex(where: { anchor($0) == after }) else { throw VoicePageError.refreshRequired }
                start = index + 1
            }
        }
        let version = Data(SHA256.hash(data: try VoiceSignalFormat.canonicalJSON(rows)))
        var items: [Row] = []
        var next = start < ordered.endIndex ? VoicePageCursor(session: session, list: query.list, after: query.cursor?.after) : nil
        for index in start..<ordered.endIndex {
            let candidate = VoicePage(items: items + [ordered[index]], nextCursor: index + 1 < ordered.endIndex
                                      ? .init(session: session, list: query.list, after: anchor(ordered[index])) : nil)
            let result = VoicePageResult(query: query.id, session: session, version: version, content: wrap(candidate))
            guard try VoiceSignalFormat.canonicalJSON(VoiceSignalPayload.pageResult(result: result)).count <= limit else {
                if items.isEmpty, limit == VoiceSignalFormat.maximumPlaintextBytes { throw VoicePageError.tooLarge }
                break
            }
            items = candidate.items
            next = candidate.nextCursor
        }
        return .init(page: .init(items: items, nextCursor: next), version: version)
    }
}
