import CueStore
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

/// 输入框里的东西：文字、图片、带上的灵感或任务（可带几张，按带上的顺序；第一张是这次关联的那条——发给 Agent 时是那条提示词）、
/// 对 Agent 回答的批注（只有会话的回复框有，按在对话里的先后）。存成卡片（随手记）、发给 Pi（回复）、开场的话（新会话）都是它，
/// 去处只决定怎么处理这份草稿。
struct ComposerDraft {
    var text = ""
    var images: [PickedImage] = []
    var attachments: [Outbox] = []
    var notes: [ReplyNote] = []

    /// 一行的草稿预览（会话行"草稿 …"、看历史时收起的回复框）：文字的第一行，没有文字时写带了什么；空的为 nil。
    var preview: String? {
        if let line = text.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
            return line
        }
        let parts = [
            notes.isEmpty ? nil : "\(notes.count) 条批注",
            attachments.isEmpty ? nil : "\(attachments.count) 条灵感",
            images.isEmpty ? nil : "\(images.count) 张图片",
        ].compactMap { $0 }
        return parts.isEmpty ? nil : "带了 " + parts.joined(separator: "、")
    }

    /// 带的内容里有没有图片：自己选的，或带上的卡片里的。
    var hasImages: Bool { !images.isEmpty || attachments.contains { !CardText($0.content).images.isEmpty } }

    /// "＋ 选灵感"带上一张（作为这次消息的附件，卡片本身不动）；已带着的不重复。
    mutating func attach(_ card: Card) {
        guard !attachments.contains(where: { $0.card == card.id }) else { return }
        attachments.append(Outbox(content: Outgoing.text(of: card), card: card.id, project: card.projectID))
    }

    /// 把存储格式正文放回输入框（编辑后重发）：文字接在已写的字后面（空一行），图片接进图片条。本机没有文件的图片略过。
    mutating func append(stored: String, files: AttachmentFiles) {
        text = [text, CueFormat.plainText(stored)].filter { !$0.allSatisfy(\.isWhitespace) }.joined(separator: "\n\n")
        images += CueFormat.imageHashes(in: stored).compactMap { hash in
            files.fileURL(for: hash).flatMap { try? Data(contentsOf: $0) }.flatMap(PickedImage.init(data:))
        }
    }

    /// 按去处接受的种类，有没有可发的东西（不接受的种类不算）。
    func isEmpty(accepting kinds: ComposerKinds) -> Bool {
        text.allSatisfy(\.isWhitespace) && (!kinds.contains(.images) || images.isEmpty) && (!kinds.contains(.cards) || attachments.isEmpty)
            && (!kinds.contains(.notes) || notes.isEmpty)
    }

    /// 只留去处收得下的：收不了图片时（会话做不到，`AgentCapabilities.images`）自己选的图片不带、带上的卡片里的图片去掉，只发文字。
    /// 草稿里可能有看不见的图片（调回的上一句、展开编辑的卡片、编辑后重发的话），发出前都经这里，界面上没露出的不会跟着发出去。
    func accepting(_ kinds: ComposerKinds) -> ComposerDraft {
        guard !kinds.contains(.images) else { return self }
        var draft = self
        draft.images = []
        draft.attachments = attachments.map { outbox in
            var outbox = outbox
            outbox.content = CueFormat.withoutImages(outbox.content)
            return outbox
        }
        return draft
    }

    /// 存储格式正文：图片文件在这里写入图片库。批注（`ReplyNote.message`）排在你写的话前面。
    func stored(in files: AttachmentFiles) throws -> String {
        StoredBody.make(
            attachments: attachments.map(\.content), text: [ReplyNote.message(notes), text].filter { !$0.isEmpty }.joined(separator: "\n\n"),
            imageHashes: try images.map { try files.store($0.data) })
    }
}

/// 一个去处接受草稿里的哪几种东西。
struct ComposerKinds: OptionSet {
    let rawValue: Int
    static let images = ComposerKinds(rawValue: 1)
    static let cards = ComposerKinds(rawValue: 2)
    static let notes = ComposerKinds(rawValue: 4)
}

/// 左边"＋"能打开的来源：卡片两端都有；图片 iOS 是相册与拍照，Mac 是图片文件（各平台的选项见 `imageChoices`）。
enum ComposerSource { case cards, photos, camera, files }

extension Binding where Value == ComposerSource? {
    /// 这个来源是不是正开着（给系统的相册、相机、面板的 `isPresented` 用）。
    func isOn(_ target: ComposerSource) -> Binding<Bool> {
        Binding<Bool>(get: { wrappedValue == target }, set: { if !$0, wrappedValue == target { wrappedValue = nil } })
    }
}

/// 选来的一张图：相册里的 HEIC 等格式转成 JPEG（Pi 与大多数应用不认 HEIC），PNG 与 JPEG 原样保留（`init(data:)` 在各平台的文件里）。
struct PickedImage: Identifiable {
    let id = UUID()
    let data: Data
    let preview: Image

    static let quality = 0.85

    /// PNG 与 JPEG 不转。
    static func keeps(_ data: Data) -> Bool { data.starts(with: [0x89, 0x50, 0x4E, 0x47]) || data.starts(with: [0xFF, 0xD8, 0xFF]) }
}
