import CueText
import Foundation
import UniformTypeIdentifiers

public enum PreviewKind: String, Codable, Sendable, CaseIterable {
  // 顺序即归类的先后：SVG 也是图片、HTML、Markdown 与 diff 也是文本，先认出来的算数
  case web, markdown, image, video, audio, pdf, document, spreadsheet, presentation, model, diff, text

  private var types: [UTType] {
    switch self {
    case .web: [.html, .svg]
    case .markdown: [UTType("net.daringfireball.markdown")].compactMap { $0 }
    case .image: [.image]
    case .video: [.movie]
    case .audio: [.audio]
    case .pdf: [.pdf]
    case .document: ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "com.apple.iwork.pages.sffpages"].compactMap(UTType.init) + [.rtf]
    case .spreadsheet: ["org.openxmlformats.spreadsheetml.sheet", "com.microsoft.excel.xls", "com.apple.iwork.numbers.sffnumbers"].compactMap(UTType.init)
    case .presentation: ["org.openxmlformats.presentationml.presentation", "com.microsoft.powerpoint.ppt", "com.apple.iwork.keynote.sffkey"].compactMap(UTType.init)
    case .model: [.usdz, .realityFile]
    case .diff: [UTType("public.patch-file")].compactMap { $0 }
    case .text: [.text]
    }
  }

  public var label: String {
    switch self {
    case .web: String(localized: "网页")
    case .markdown: "Markdown"
    case .image: String(localized: "图片")
    case .video: String(localized: "视频")
    case .audio: String(localized: "音频")
    case .pdf: "PDF"
    case .document: String(localized: "文稿")
    case .spreadsheet: String(localized: "表格")
    case .presentation: String(localized: "演示文稿")
    case .model: String(localized: "3D 模型")
    case .diff: String(localized: "改动")
    case .text: String(localized: "文本")
    }
  }

  /// 类型按附件键认（`AttachmentKey.type`）：系统认错的 .ts 等在那里已按文本算，快速查看打开的也是同一份。
  public init?(fileName: String) {
    guard !Self.unreadable.contains(AttachmentKey.format(ofName: fileName)), let type = AttachmentKey.type(ofName: fileName),
      let kind = Self.allCases.first(where: { $0.types.contains { type.conforms(to: $0) } })
    else { return nil }
    self = kind
  }

  /// 系统认得、这里却显示不了的：.svgz 是 gzip 压缩的 SVG，网页预览按原字节载入、不解压。
  private static let unreadable: Set<String> = ["svgz"]

  public static let supportedList = allCases.map { kind in
    let extensions = kind.types.flatMap { $0.tags[.filenameExtension] ?? [] }.filter { !unreadable.contains($0) }
    return extensions.isEmpty || extensions == [kind.label.lowercased()] ? kind.label : "\(kind.label)（\(extensions.joined(separator: "、"))）"
  }.joined(separator: "、")
}

public struct PreviewItem: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var sessionID: String
  public var hash: String
  public var name: String
  public var title: String
  public var byteCount: Int
  public var createdAt: Date
  public var modifiedAt: Date

  public static let maxBytes = 20_000_000
  public static let titleLimit = 40
  public static let titleRule = "说清这份是什么、看哪里，用和用户对话的语言；一行、宽不过 \(titleLimit)（约 \(titleLimit / 2) 个汉字），同一次发的各不相同"

  public var kind: PreviewKind? { PreviewKind(fileName: name) }

  public var key: String { AttachmentKey.make(hash: hash, name: name) }

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

extension PreviewItem: Record, SyncedColumns {
  static let table = Table.previews
  static let fields: [Field] = [
    .plain("id"), .plain("sessionID"), .plain("hash"), .encrypted("name"), .encrypted("title"), .plain("byteCount"),
    .plain("createdAt"), .plain("modifiedAt"),
  ]
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

public enum PreviewTitleProblem: Equatable, Sendable {
  case blank, multiline, tooWide(Int), repeated

  var phrase: String {
    switch self {
    case .blank: "是空的"
    case .multiline: "不止一行"
    case .tooWide(let width): "宽 \(width)，超过 \(PreviewItem.titleLimit)"
    case .repeated: "与同一次发的另一份重复"
    }
  }
}

public struct PreviewAdded: Equatable, Sendable {
  public var preview: PreviewItem
  public var outsideReferences: [String]

  static let referenceLimit = 5
}

extension CueStore {
  public func addPreviews(_ sent: [(url: URL, title: String)], sessionID: String) throws -> [PreviewAdded] {
    var titles: [String] = []
    for file in sent {
      let title = file.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let width = CueName.width(title)
      let problem: PreviewTitleProblem? =
        if title.isEmpty { .blank } else if title.contains(where: \.isNewline) { .multiline }
        else if width > PreviewItem.titleLimit { .tooWide(width) } else if titles.contains(title) { .repeated } else { nil }
      if let problem { throw CueStoreError.previewTitle(file.url.lastPathComponent, problem) }
      titles.append(title)
    }
    let urls = sent.map(\.url)
    let checked = try urls.map { url in
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
      guard attributes?[.type] as? FileAttributeType == .typeRegular, let size = attributes?[.size] as? Int else {
        throw CueStoreError.previewUnreadable(url.path)
      }
      guard let kind = PreviewKind(fileName: url.lastPathComponent) else { throw CueStoreError.previewUnsupported(url.pathExtension.lowercased()) }
      guard size <= PreviewItem.maxBytes else { throw CueStoreError.previewTooLarge(url.path, bytes: size) }
      return (url: url, kind: kind, size: size)
    }
    let hashes = try checked.map { file in
      guard let key = try? files.store(fileAt: file.url), let hash = AttachmentKey.parts(key)?.hash else {
        throw CueStoreError.previewUnreadable(file.url.path)
      }
      return hash
    }
    let ids = urls.map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }
    let previews = try write {
      let latest = try db.query("SELECT max(createdAt) FROM previews WHERE sessionID = ?", [sessionID]) { $0.dateOrNil(0) }.first ?? nil
      let createdAt = latest.map { max(Date.stamp, $0.addingTimeInterval(0.001)) } ?? Date.stamp
      let previews = checked.indices.map { index in
        PreviewItem(
          id: ids[index], sessionID: sessionID, hash: hashes[index], name: checked[index].url.lastPathComponent, title: titles[index],
          byteCount: checked[index].size, createdAt: createdAt)
      }
      for preview in previews {
        try registerAttachment(preview.key)
        try insert(preview)
      }
      return previews
    }
    return zip(previews, checked).map { preview, file in
      PreviewAdded(preview: preview, outsideReferences: file.kind == .web ? PreviewAdded.outsideReferences(inHTMLAt: file.url) : [])
    }
  }

  public func previews(of sessionID: String) throws -> [PreviewItem] {
    try select(PreviewItem.self, where: "sessionID = ?", [sessionID], orderBy: "createdAt, id")
  }

  public func previews(_ ids: some Collection<UUID>) throws -> [UUID: PreviewItem] {
    guard !ids.isEmpty else { return [:] }
    let found = try select(PreviewItem.self, where: "id IN (SELECT value FROM json_each(?))", [Self.idList(ids)])
    return Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
  }
}

extension PreviewAdded {
  static func outsideReferences(inHTMLAt url: URL) -> [String] {
    guard let source = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    let html = source.replacing(scriptBody) { String($0.output.1) + "</script>" }
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

  private static var scriptBody: Regex<(Substring, Substring)> { /(?is)(<script\b[^>]*>).*?<\/script\s*>/ }

  private static let reference = try! NSRegularExpression(
    pattern: #"<(?:link\b[^>]*?\bhref|(?:script|img|source|video|audio|iframe)\b[^>]*?\bsrc)\s*=\s*(["'])(.*?)\1"#, options: [.caseInsensitive])
}
