import CueStore
import CueEditor
import CueText
import SwiftUI

struct Outbox: Identifiable {
    let id = UUID()
    var content: String
    var card: UUID?
    var project: UUID?

    var launchKey: SessionLaunching.Key { card.map { .card($0) } ?? .form }
}

struct ComposerDraft {
    var text = ""
    var files: [DraftFile] = []
    var attachments: [Outbox] = []
    var notes: [ReplyNote] = []
    var importing: [UUID] = []

    var preview: String? {
        var rest = text[...]
        while !rest.isEmpty {
            let end = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
            let line = rest[..<end].trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line }
            rest = end == rest.endIndex ? "" : rest[rest.index(after: end)...]
        }
        let parts = [
            notes.isEmpty ? nil : String(localized: "\(notes.count) 条批注"),
            attachments.isEmpty ? nil : String(localized: "\(attachments.count) 条灵感"),
            files.isEmpty ? nil : String(localized: "\(files.count) 个附件"),
        ].compactMap { $0 }
        return parts.isEmpty ? nil : String(localized: "带了 \(parts.formatted(.list(type: .and)))")
    }

    var hasFiles: Bool { !files.isEmpty || attachments.contains { CueFormat.hasAttachments($0.content) } }

    mutating func attach(_ card: Card) {
        guard !attachments.contains(where: { $0.card == card.id }) else { return }
        attachments.append(Outbox(content: Outgoing.text(of: card), card: card.id, project: card.projectID))
    }

    func retelling(_ card: UUID?, as content: String?) -> ComposerDraft {
        guard let card, let content else { return self }
        var draft = self
        for index in draft.attachments.indices where draft.attachments[index].card == card { draft.attachments[index].content = content }
        return draft
    }

    mutating func append(stored: String) {
        let tokens = CueFormat.parse(stored)
        let words = tokens.map { if case .text(let text) = $0 { text } else { "" } }.joined()
        text = [text, CueFormat.plainText(words)].filter { !$0.allSatisfy(\.isWhitespace) }.joined(separator: "\n\n")
        for file in tokens.compactMap(DraftFile.init) where !files.contains(file) { files.append(file) }
    }

    func isEmpty(accepting kinds: ComposerKinds) -> Bool {
        text.allSatisfy(\.isWhitespace) && (!kinds.contains(.files) || files.isEmpty && importing.isEmpty) && (!kinds.contains(.cards) || attachments.isEmpty)
            && (!kinds.contains(.notes) || notes.isEmpty)
    }

    func accepting(_ kinds: ComposerKinds) -> ComposerDraft {
        guard !kinds.contains(.files) else { return self }
        var draft = self
        draft.files = []
        draft.importing = []
        draft.attachments = attachments.map { outbox in
            var outbox = outbox
            outbox.content = CueFormat.plainText(outbox.content)
            return outbox
        }
        return draft
    }

    var stored: String {
        StoredBody.make(attachments: attachments.map(\.content), text: ReplyNote.message(notes, said: text), files: files)
    }
}

struct ComposerKinds: OptionSet {
    let rawValue: Int
    static let files = ComposerKinds(rawValue: 1)
    static let cards = ComposerKinds(rawValue: 2)
    static let notes = ComposerKinds(rawValue: 4)
    static let reply: ComposerKinds = [.files, .cards, .notes]
}

enum ComposerSource { case cards, photos, camera, files }

extension Binding where Value == ComposerSource? {
    func isOn(_ target: ComposerSource) -> Binding<Bool> {
        Binding<Bool>(get: { wrappedValue == target }, set: { if !$0, wrappedValue == target { wrappedValue = nil } })
    }
}

nonisolated struct DraftFile: Identifiable, Hashable, Sendable {
    let key: String
    let name: String

    var id: String { key }

    init(key: String, name: String) {
        self.key = key
        self.name = name
    }

    init?(_ token: CueToken) {
        switch token {
        case .text: return nil
        case .image(let key): self.init(key: key, name: "")
        case .file(let key, let name): self.init(key: key, name: name)
        }
    }

    static func == (lhs: DraftFile, rhs: DraftFile) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
    var isImage: Bool { AttachmentKey.isImage(key) }
    var markup: String { CueFormat.markup(key: key, name: name) }

    @concurrent static func store(_ incoming: IncomingFile, in files: AttachmentFiles) async throws -> DraftFile {
        let stored = try await incoming.store(in: files)
        return DraftFile(key: stored.key, name: stored.name)
    }
}
