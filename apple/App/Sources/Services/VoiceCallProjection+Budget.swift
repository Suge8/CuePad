import Foundation

extension VoiceCallProjection.RequestPreview {
    /// 上限按 UTF-8 计算，保留完整字形；JSON 转义后的体积由整份快照预算另行核算。
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
    /// 优先未保存的请求，再保留停止目标、近期朗读与已保存请求引用。
    /// 逐项按真实 JSON 字节预算；省略计数从总数递减，数字只会缩短，数组逗号预留一字节，最终封包不会越过明文上限。
    func bounded() throws -> Self {
        var result = Self(session: session, phase: phase, requests: [], replies: [], executions: [], response: response,
                          omitted: .init(requests: requests.count, replies: replies.count, executions: executions.count))
        var budget = VoiceSignalFormat.maximumPlaintextBytes - (try VoiceSignalFormat.canonicalJSON(VoiceSignalPayload.projection(value: result))).count
        let unsaved = requests.filter { if case .unrecorded = $0.reference { true } else { false } }
        let saved = requests.filter { if case .recorded = $0.reference { true } else { false } }
        let keptUnsaved = try Self.select(unsaved, budget: &budget)
        let keptExecutions = try Self.select(executions, budget: &budget)
        let keptReplies = try Self.select(replies, budget: &budget)
        let keptSaved = try Self.select(saved, budget: &budget)
        let keptRequests = keptUnsaved + keptSaved
        result.omitted.requests -= keptRequests.count
        result.omitted.replies -= keptReplies.count
        result.omitted.executions -= keptExecutions.count
        return Self(session: session, phase: phase, requests: keptRequests, replies: keptReplies, executions: keptExecutions,
                    response: response, omitted: result.omitted)
    }

    private static func select<Row: Encodable>(_ rows: [Row], budget: inout Int) throws -> [Row] {
        var kept: [Row] = []
        for row in rows.reversed() {
            let size = try VoiceSignalFormat.canonicalJSON(row).count + 1
            guard size <= budget else { continue }
            kept.append(row)
            budget -= size
        }
        return kept.reversed()
    }
}
