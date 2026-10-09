import Foundation

/// 预览能给手机看的文件类型，由文件名的扩展名定（唯一定义）：HTML 在只读的网页里渲染，其余交给系统的快速查看。
public enum PiPreviewKind: String, Sendable, CaseIterable {
  case web, image, pdf, markdown, text

  private static let extensions: [String: PiPreviewKind] = [
    "html": .web, "htm": .web, "svg": .web,
    "png": .image, "jpg": .image, "jpeg": .image, "gif": .image, "webp": .image, "heic": .image,
    "pdf": .pdf, "md": .markdown, "markdown": .markdown,
    "txt": .text, "json": .text, "csv": .text, "log": .text,
  ]

  public init?(fileName: String) {
    guard let kind = Self.extensions[URL(filePath: fileName).pathExtension.lowercased()] else { return nil }
    self = kind
  }

  /// 给 Agent 与用户看的"可发什么"。
  public static let supportedList = "HTML、图片（png、jpg、gif、webp、heic、svg）、PDF、Markdown、文本（txt、json、csv、log）"
}

/// Agent 发到手机上看的一个文件（同步表 `previews`，Mac 写、各端读）：文件按内容哈希存在附件目录、经附件记录同步，
/// 这里只记它属于哪个 Pi 会话、叫什么、多大。对话里预览出现的位置不在这里，由会话文件里的工具调用那一行定（`PiChatRole.preview`）。
public struct PiPreview: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// Pi 自己的会话 id（同 `PiSessionState.sessionID`）
  public var sessionID: String
  public var hash: String
  /// 原文件名（含扩展名，类型由它定）
  public var name: String
  /// 一句标题；没给时是不带扩展名的文件名
  public var title: String
  public var byteCount: Int
  public var createdAt: Date
  public var modifiedAt: Date

  /// 单个文件上限：手机上经 iCloud 同步，演示与验收用的页面和截图远小于它。
  public static let maxBytes = 20_000_000

  public var kind: PiPreviewKind? { PiPreviewKind(fileName: name) }

  public init(id: UUID = UUID(), sessionID: String, hash: String, name: String, title: String, byteCount: Int, createdAt: Date? = nil) {
    let createdAt = createdAt ?? .stamp
    self.id = id
    self.sessionID = sessionID
    self.hash = hash
    self.name = name
    self.title = title
    self.byteCount = byteCount
    self.createdAt = createdAt
    modifiedAt = createdAt
  }
}

extension PiPreview: Record {
  static let table = Table.previews
  static let columns = ["id", "sessionID", "hash", "name", "title", "byteCount", "createdAt", "modifiedAt"]
  var bindings: [any SQLBindable] { [id, sessionID, hash, name, title, byteCount, createdAt, modifiedAt] }
  init(row: Row) {
    id = row.uuid(0)
    sessionID = row.text(1)
    hash = row.text(2)
    name = row.text(3)
    title = row.text(4)
    byteCount = Int(row.int(5))
    createdAt = row.date(6)
    modifiedAt = row.date(7)
  }
}

/// `CueStore.addPreview` 的结果：预览，以及 HTML 里引用了、手机上预览时拿不到的外部资源。
public struct PiPreviewAdded: Equatable, Sendable {
  public var preview: PiPreview
  /// 页面引用的本地文件或网络地址（预览只读单个文件、不联网）：缺的会显示不全，给 Agent 看，让它改成单文件再发。最多 `PiPreviewAdded.referenceLimit` 个
  public var outsideReferences: [String]

  public static let referenceLimit = 5
}

extension CueStore {
  /// 把文件放进某个 Pi 会话的预览：按内容哈希存进附件目录（同内容共用一份），在同一事务里登记附件记录与预览记录（同步给手机）。
  /// 文件不存在、不是文件、太大或类型不支持时抛 `CueStoreError.preview…`，什么都不留下。
  public func addPreview(fileAt url: URL, title: String?, sessionID: String) throws -> PiPreviewAdded {
    let path = url.path
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    guard attributes?[.type] as? FileAttributeType == .typeRegular, let size = attributes?[.size] as? Int else {
      throw CueStoreError.previewUnreadable(path)
    }
    let name = url.lastPathComponent
    guard let kind = PiPreviewKind(fileName: name) else { throw CueStoreError.previewUnsupported(url.pathExtension.lowercased()) }
    guard size <= PiPreview.maxBytes else { throw CueStoreError.previewTooLarge(limit: PiPreview.maxBytes) }
    guard let hash = try? files.storeFile(at: url) else { throw CueStoreError.previewUnreadable(path) }

    let given = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let preview = PiPreview(
      sessionID: sessionID, hash: hash, name: name, title: given.isEmpty ? url.deletingPathExtension().lastPathComponent : given, byteCount: size)
    try write {
      try registerAttachment(hash: hash)
      try insert(preview)
    }
    let references = kind == .web ? PiPreviewAdded.outsideReferences(inHTMLAt: url) : []
    return PiPreviewAdded(preview: preview, outsideReferences: references)
  }

  /// 一个会话的预览，从早到晚。
  public func previews(of sessionID: String) throws -> [PiPreview] {
    try select(PiPreview.self, where: "sessionID = ?", [sessionID], orderBy: "createdAt, id")
  }
}

extension PiPreviewAdded {
  /// 页面里 `<link href>`（样式、图标）与 `<script|img|source|video|audio|iframe src>` 指向的不是 data:、blob:、页内锚点的地址，按出现的先后、去重。
  static func outsideReferences(inHTMLAt url: URL) -> [String] {
    guard let html = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var seen: [String] = []
    for match in reference.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
      guard let range = Range(match.range(at: 2), in: html) else { continue }
      let address = String(html[range]).trimmingCharacters(in: .whitespaces)
      let local = ["data:", "blob:", "#", "about:", "javascript:"].contains { address.lowercased().hasPrefix($0) }
      if !address.isEmpty, !local, !seen.contains(address) { seen.append(address) }
      if seen.count == referenceLimit { break }
    }
    return seen
  }

  private static let reference = try! NSRegularExpression(
    pattern: #"<(?:link\b[^>]*?\bhref|(?:script|img|source|video|audio|iframe)\b[^>]*?\bsrc)\s*=\s*(["'])(.*?)\1"#, options: [.caseInsensitive])
}
