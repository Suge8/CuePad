import CueStore
import CueEditor
import CueText
import SwiftUI

struct Outbox: Identifiable {
    let id = UUID()
    var content: String
    var card: UUID?
    var project: UUID?
}

struct ComposerDraft {
    var text = ""
    var files: [DraftFile] = []
    var attachments: [Outbox] = []
    var notes: [ReplyNote] = []
    /// 存好前就发出的话，发的人按它们等附件（`Workspace.claimImports`）。
    var importing: [UUID] = []

    var preview: String? {
        // 逐行往下找到第一行有字的就停：草稿几百行时不把整串切成行（会话行与回复框每次重算都要问）
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

    /// 草稿里可能有看不见的附件（调回的上一句、展开编辑的卡片、编辑后重发的话），发出前都经这里，界面上没露出的不会跟着发出去。
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

    /// 批注与引用的预览按 `ReplyNote.message` 接上你写的话。
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

/// 粘贴、拖进来的附件不经这里，由文字区直接交进附件条。
enum ComposerSource { case cards, photos, camera, files }

extension Binding where Value == ComposerSource? {
    func isOn(_ target: ComposerSource) -> Binding<Bool> {
        Binding<Bool>(get: { wrappedValue == target }, set: { if !$0, wrappedValue == target { wrappedValue = nil } })
    }
}

/// 选好就存进附件目录（`store`，在后台：大文件要读一遍算哈希），草稿里只记键与文件名。同一份内容就是同一个附件（身份与相等都只看键）：改了名再选一次不多一个，附件条与对话里的文件牌身份不重。
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
