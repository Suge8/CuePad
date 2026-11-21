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
    static let shownLimit = 30

    func bounded() throws -> Self {
        var requests = Array(self.requests.suffix(Self.shownLimit))
        var replies = Array(self.replies.suffix(Self.shownLimit))
        func value() -> Self {
            Self(session: session, phase: phase, requests: requests, replies: replies, response: response,
                 omitted: .init(requests: self.requests.count - requests.count, replies: self.replies.count - replies.count), canRepeat: canRepeat)
        }
        while try VoiceSignalFormat.canonicalJSON(VoiceSignalPayload.projection(value: value())).count > VoiceSignalFormat.maximumPlaintextBytes {
            guard !requests.isEmpty || !replies.isEmpty else { throw VoiceSignalError.tooLarge }
            if requests.count >= replies.count { requests.removeFirst() } else { replies.removeFirst() }
        }
        return value()
    }
}
