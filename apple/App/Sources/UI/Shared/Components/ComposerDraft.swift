import CueStore
import CueEditor
import CueText
import SwiftUI

/// 带上的一张卡片或任务（输入框里的，或 iOS 发给 Agent 时浮起的那一份）。
struct Outbox: Identifiable {
    let id = UUID()
    var content: String
    var card: UUID?
    /// 卡片所在项目：选会话时它的会话排在前面。
    var project: UUID?
}

/// 输入框里的东西：文字、附件（图片与文件）、带上的灵感或任务（可带几张，按带上的顺序；第一张是这次关联的那条——发给 Agent 时是那件任务）、
/// 对 Agent 回答的批注（只有会话的回复框有，按在对话里的先后）。存成卡片（随手记）、发给 Pi（回复）、开场的话（新会话）都是它，
/// 去处只决定怎么处理这份草稿。
struct ComposerDraft {
    var text = ""
    var files: [DraftFile] = []
    var attachments: [Outbox] = []
    var notes: [ReplyNote] = []

    /// 一行的草稿预览（会话行"草稿 …"、看历史时收起的回复框）：文字的第一行，没有文字时写带了什么；空的为 nil。
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

    /// "＋ 选灵感"带上一张（作为这次消息的附件，卡片本身不动）；已带着的不重复。
    mutating func attach(_ card: Card) {
        guard !attachments.contains(where: { $0.card == card.id }) else { return }
        attachments.append(Outbox(content: Outgoing.text(of: card), card: card.id, project: card.projectID))
    }

    /// 带着的 `card` 那一张换成 `content`（开新会话时，任务的第一句换成带着顶层任务作背景的那句，`CueStore.opening`）。
    func retelling(_ card: UUID?, as content: String?) -> ComposerDraft {
        guard let card, let content else { return self }
        var draft = self
        for index in draft.attachments.indices where draft.attachments[index].card == card { draft.attachments[index].content = content }
        return draft
    }

    /// 把存储格式正文放回输入框（编辑后重发、展开编辑带上的卡片）：文字接在已写的字后面（空一行），附件接进附件条（已带着的不重复）。
    mutating func append(stored: String) {
        let tokens = CueFormat.parse(stored)
        let words = tokens.map { if case .text(let text) = $0 { text } else { "" } }.joined()
        text = [text, CueFormat.plainText(words)].filter { !$0.allSatisfy(\.isWhitespace) }.joined(separator: "\n\n")
        for token in tokens {
            let file: DraftFile? = switch token {
            case .text: nil
            case .image(let key): DraftFile(key: key, name: "")
            case .file(let key, let name): DraftFile(key: key, name: name)
            }
            if let file, !files.contains(file) { files.append(file) }
        }
    }

    /// 按去处接受的种类，有没有可发的东西（不接受的种类不算）。
    func isEmpty(accepting kinds: ComposerKinds) -> Bool {
        text.allSatisfy(\.isWhitespace) && (!kinds.contains(.files) || files.isEmpty) && (!kinds.contains(.cards) || attachments.isEmpty)
            && (!kinds.contains(.notes) || notes.isEmpty)
    }

    /// 只留去处收得下的：收不了附件时（作答的回复框只收文字）自己带的附件不带、带上的卡片里的附件只留文件名。
    /// 草稿里可能有看不见的附件（调回的上一句、展开编辑的卡片、编辑后重发的话），发出前都经这里，界面上没露出的不会跟着发出去。
    func accepting(_ kinds: ComposerKinds) -> ComposerDraft {
        guard !kinds.contains(.files) else { return self }
        var draft = self
        draft.files = []
        draft.attachments = attachments.map { outbox in
            var outbox = outbox
            outbox.content = CueFormat.plainText(outbox.content)
            return outbox
        }
        return draft
    }

    /// 存储格式正文（附件选好时已存进附件目录）。批注（`ReplyNote.message`）排在你写的话前面。
    var stored: String {
        StoredBody.make(
            attachments: attachments.map(\.content), text: [ReplyNote.message(notes), text].filter { !$0.isEmpty }.joined(separator: "\n\n"),
            files: files)
    }
}

struct ComposerKinds: OptionSet {
    let rawValue: Int
    /// 附件：图片与任意文件（交给 Agent 的是本机路径，各家都读得了）
    static let files = ComposerKinds(rawValue: 1)
    static let cards = ComposerKinds(rawValue: 2)
    static let notes = ComposerKinds(rawValue: 4)
}

/// 左边"＋"能打开的来源：卡片两端都有；附件 iOS 是相册、拍照与文件，Mac 是文件（各平台的选项见 `fileChoices`）。粘贴、拖进来的附件不经这里，由文字区直接交进附件条。
enum ComposerSource { case cards, photos, camera, files }

extension Binding where Value == ComposerSource? {
    /// 这个来源是不是正开着（给系统的相册、相机、面板的 `isPresented` 用）。
    func isOn(_ target: ComposerSource) -> Binding<Bool> {
        Binding<Bool>(get: { wrappedValue == target }, set: { if !$0, wrappedValue == target { wrappedValue = nil } })
    }
}

/// 带上的一个附件（相册、拍照、文件、粘贴、拖入）：选好就存进附件目录（`store`，在后台：大文件要读一遍算哈希），草稿里只记键与文件名，
/// 发出去就是正文里的引用（`CueFormat.markup`）。图片没有名字（嵌入的写法不带名字）。
/// 同一份内容就是同一个附件（身份与相等都只看键）：改了名再选一次不多一个，附件条与对话里的文件牌身份不重。
nonisolated struct DraftFile: Identifiable, Hashable, Sendable {
    let key: String
    let name: String

    var id: String { key }

    static func == (lhs: DraftFile, rhs: DraftFile) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
    var isImage: Bool { AttachmentKey.isImage(key) }
    var markup: String { CueFormat.markup(key: key, name: name) }

    @concurrent static func store(_ incoming: IncomingFile, in files: AttachmentFiles) async throws -> DraftFile {
        let stored = try incoming.store(in: files)
        return DraftFile(key: stored.key, name: stored.name)
    }
}
