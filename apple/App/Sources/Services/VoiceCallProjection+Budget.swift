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
    /// 发给手机的每类最多这么多条（最近的）；再超出信令帧的明文上限时，从条目最多的那类再去掉最旧的。
    static let shownLimit = 30

    /// 发给手机的这一份：只带最近的条目，其余记进 omitted。
    func bounded() throws -> Self {
        var requests = Array(self.requests.suffix(Self.shownLimit))
        var replies = Array(self.replies.suffix(Self.shownLimit))
        var executions = Array(self.executions.suffix(Self.shownLimit))
        func value() -> Self {
            Self(session: session, phase: phase, requests: requests, replies: replies, executions: executions, response: response,
                 omitted: .init(requests: self.requests.count - requests.count, replies: self.replies.count - replies.count,
                                executions: self.executions.count - executions.count), canRepeat: canRepeat)
        }
        while try VoiceSignalFormat.canonicalJSON(VoiceSignalPayload.projection(value: value())).count > VoiceSignalFormat.maximumPlaintextBytes {
            let longest = max(requests.count, replies.count, executions.count)
            guard longest > 0 else { throw VoiceSignalError.tooLarge }
            if requests.count == longest { requests.removeFirst() }
            else if replies.count == longest { replies.removeFirst() }
            else { executions.removeFirst() }
        }
        return value()
    }
}
