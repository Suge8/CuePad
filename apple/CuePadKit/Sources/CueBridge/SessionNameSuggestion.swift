#if os(macOS)
import CueStore
import Foundation

public enum SessionNameSuggestion {
    static let limit = 36
    static let budget: Duration = .seconds(8)

    static let instructions = """
        Generate a concise, single-line task title of at most \(limit) characters and under five words where possible. \
        Start with an imperative verb. Capitalize only the first word unless the user's language, proper nouns, acronyms, \
        or code terms require otherwise. Preserve ticket references exactly. Write in the user's language. \
        Do not use quotes, markdown, or trailing punctuation. Do not answer the request.
        """

    static func cleaned(_ reply: String) -> String? {
        let line = reply.split(whereSeparator: \.isNewline).first.map { String($0.trimmingCharacters(in: .whitespaces).prefix(limit)) } ?? ""
        return line.isEmpty ? nil : line
    }
}

extension Bridge {
    public func canNameItself(_ id: Session.ID) -> Bool { controls[id]?.canNameItself(id) ?? false }

    public func suggestName(for id: Session.ID) async throws -> String {
        guard let link = controls[id], let first = session(id: id)?.firstMessage else { throw BridgeError.unknownSession(id) }
        return try await link.suggestName(from: SessionName.display(name: nil, firstMessage: first, folder: ""), in: id)
    }
}
#endif
