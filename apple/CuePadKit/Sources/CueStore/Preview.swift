import CueText
import Foundation
import UniformTypeIdentifiers

/// 能发到手机上看的文件类型（唯一定义）：按文件名的扩展名得出系统类型（UTType），归进第一个它属于的类。
/// 网页与 Markdown 在 CuePad 自己的页里看（网页只读、不联网），其余交给系统的快速查看。
public enum PiPreviewKind: String, Sendable, CaseIterable {
  // 顺序即归类的先后：SVG 也是图片、HTML 与 Markdown 也是文本，先认出来的算数
  case web, markdown, image, video, audio, pdf, document, spreadsheet, presentation, model, text

  /// 属于这一类的系统类型；具体类型（带扩展名的）会写进"可发什么"。
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
    case .text: [.text]
    }
  }

  public var label: String {
    switch self {
    case .web: "网页"
    case .markdown: "Markdown"
    case .image: "图片"
    case .video: "视频"
    case .audio: "音频"
    case .pdf: "PDF"
    case .document: "文稿"
    case .spreadsheet: "表格"
    case .presentation: "演示文稿"
    case .model: "3D 模型"
    case .text: "文本"
    }
  }

  public init?(fileName: String) {
    guard let type = Self.type(ofExtension: Self.pathExtension(fileName)),
      let kind = Self.allCases.first(where: { $0.types.contains { type.conforms(to: $0) } })
    else { return nil }
    self = kind
  }

  /// 系统把 .ts、.mts 认作 MPEG-2 传输流（视频），可 Agent 发来的几乎都是 TypeScript：这几个按源代码（文本）认。
  /// 用通用的源代码类型：TypeScript 自己的类型（com.microsoft.typescript）只有装了开发工具的 Mac 上有，手机上没有。
  /// 别的同名歧义系统本来就归到文本（.m 是 Objective-C 还是 MATLAB、.r、.fs 都是源代码），不用改。
  private static let reassigned: [String: UTType] = ["ts": .sourceCode, "mts": .sourceCode, "cts": .sourceCode]
  /// 系统认得、这里却显示不了的：.svgz 是 gzip 压缩的 SVG，网页预览按原字节载入、不解压。
  private static let unreadable: Set<String> = ["svgz"]

  /// 交给系统（快速查看、缩略图）时的文件名：系统按扩展名认类型，改认过的（`reassigned`）要再接一个 .txt，否则快速查看照样当视频打开。
  static func systemFileName(_ name: String) -> String {
    reassigned[pathExtension(name)] == nil ? name : name + ".txt"
  }

  /// 文件名的扩展名（小写）。不经 `URL(filePath:)`：相对的文件名要先取一次当前目录（getcwd 系统调用），缩略图每画一次问好几遍。
  private static func pathExtension(_ name: String) -> String { (name as NSString).pathExtension.lowercased() }

  private static func type(ofExtension pathExtension: String) -> UTType? {
    let pathExtension = pathExtension.lowercased()
    guard !unreadable.contains(pathExtension) else { return nil }
    return reassigned[pathExtension] ?? UTType(filenameExtension: pathExtension)
  }

  /// 给 Agent 与用户看的"可发什么"：网页（html、htm、svg）、Markdown（md、markdown）、图片、……
  public static let supportedList = allCases.map { kind in
    let extensions = kind.types.flatMap { $0.tags[.filenameExtension] ?? [] }.filter { !unreadable.contains($0) }
    return extensions.isEmpty || extensions == [kind.label.lowercased()] ? kind.label : "\(kind.label)（\(extensions.joined(separator: "、"))）"
  }.joined(separator: "、")
}

/// Agent 发到手机上看的一个文件（同步表 `previews`，Mac 写、各端读）：文件按内容哈希存在附件目录、经附件记录同步，
/// 这里只记它属于哪个 Agent 会话、叫什么、多大。对话里的位置由创建时间定（`PiChat.entries`）。
public struct PiPreview: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// Agent 自己的会话 id（同 `PiSessionState.sessionID`）
  public var sessionID: String
  public var hash: String
  /// 原文件名（含扩展名，类型由它定）
  public var name: String
  /// 一句标题：这份是什么、看哪里（Agent 发时每份一句、同批各不相同，宽不过 `titleLimit`），缩略图下、全屏页顶上与 Cue 的清单里都写它
  public var title: String
  public var byteCount: Int
  public var createdAt: Date
  public var modifiedAt: Date

  /// 单个文件上限：手机上经 iCloud 同步，演示与验收用的页面和截图远小于它。
  public static let maxBytes = 20_000_000
  /// 标题宽不过这么多（`CueName.width`，约 20 个汉字）：缩略图下至多两行写得下。
  public static let titleLimit = 40

  /// 这台设备不认识的类型（别的版本发来的）为 nil
  public var kind: PiPreviewKind? { PiPreviewKind(fileName: name) }

  /// 本机交给系统（快速查看、缩略图）的那份文件叫什么：系统认错类型的扩展名（.ts 等）另接 .txt，按这里归的类打开。
  public var systemFileName: String { PiPreviewKind.systemFileName(name) }

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

extension AttachmentFiles {
  /// 一份预览在本机按原文件名放的那份（界面交给快速查看、Cue 的读文件工具用的都是它）；还没同步到本机为 nil。
  public func url(of preview: PiPreview) -> URL? { named(preview.hash, as: preview.systemFileName) }
}

/// `CueStore.addPreviews` 的结果，一个文件一份：预览，以及 HTML 里引用了、手机上预览时拿不到的外部资源。
public struct PiPreviewAdded: Equatable, Sendable {
  public var preview: PiPreview
  /// 页面引用的本地文件或网络地址（预览只读单个文件、不联网）：缺的会显示不全，给 Agent 看，让它改成单文件再发。最多 `PiPreviewAdded.referenceLimit` 个
  public var outsideReferences: [String]

  public static let referenceLimit = 5
}

extension CueStore {
  /// 把一次发来的几个文件（一批）放进某个 Agent 会话的预览：按内容哈希存进附件目录（同内容共用一份），在同一事务里登记附件记录与预览记录（同步给手机）。
  /// 同一批 = 同一创建时间，对话里据此收成一张卡（`PiChat.entries`），不为"一批"另加同步字段。所以一个会话里每批的创建时间各不相同：
  /// 不晚于这个会话已有最后一条预览时（两次调用落在同一毫秒、或时钟往回调过）取它之后 1 毫秒；查与写在同一个写事务里，并发的命令行也排得开。
  /// 批内 id 按参数顺序从小到大，同一时刻里按 id 排出的就是参数顺序。每份带自己的一句标题（`PiPreview.title`），同一批里各不相同：用户分得清哪张是哪张，不靠文件名。
  /// 任一个标题空着、太长或与同批重复，文件不存在、不是文件、太大或类型不支持时抛 `CueStoreError.preview…`，一个都不留下。
  /// HTML 引用的外部资源只列出来让 Agent 改成单文件，不在这里替它内联：样式里的 url()、字体、模块脚本都要处理，漏一类就是静默缺图。
  public func addPreviews(_ sent: [(url: URL, title: String)], sessionID: String) throws -> [PiPreviewAdded] {
    var titles: [String] = []
    for file in sent {
      let title = file.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty, !title.contains(where: \.isNewline), CueName.width(title) <= PiPreview.titleLimit, !titles.contains(title) else {
        throw CueStoreError.previewTitle(file.url.lastPathComponent, limit: PiPreview.titleLimit)
      }
      titles.append(title)
    }
    let urls = sent.map(\.url)
    let checked = try urls.map { url in
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
      guard attributes?[.type] as? FileAttributeType == .typeRegular, let size = attributes?[.size] as? Int else {
        throw CueStoreError.previewUnreadable(url.path)
      }
      guard let kind = PiPreviewKind(fileName: url.lastPathComponent) else { throw CueStoreError.previewUnsupported(url.pathExtension.lowercased()) }
      guard size <= PiPreview.maxBytes else { throw CueStoreError.previewTooLarge(url.path, limit: PiPreview.maxBytes) }
      return (url: url, kind: kind, size: size)
    }
    let hashes = try checked.map { file in
      guard let hash = try? files.storeFile(at: file.url) else { throw CueStoreError.previewUnreadable(file.url.path) }
      return hash
    }
    let ids = urls.map { _ in UUID() }.sorted { $0.uuidString < $1.uuidString }
    let previews = try write {
      let latest = try db.query("SELECT max(createdAt) FROM previews WHERE sessionID = ?", [sessionID]) { $0.dateOrNil(0) }.first ?? nil
      let createdAt = latest.map { max(Date.stamp, $0.addingTimeInterval(0.001)) } ?? Date.stamp
      let previews = checked.indices.map { index in
        PiPreview(
          id: ids[index], sessionID: sessionID, hash: hashes[index], name: checked[index].url.lastPathComponent, title: titles[index],
          byteCount: checked[index].size, createdAt: createdAt)
      }
      for preview in previews {
        try registerAttachment(hash: preview.hash)
        try insert(preview)
      }
      return previews
    }
    return zip(previews, checked).map { preview, file in
      PiPreviewAdded(preview: preview, outsideReferences: file.kind == .web ? PiPreviewAdded.outsideReferences(inHTMLAt: file.url) : [])
    }
  }

  /// 一个会话的预览，从早到晚。
  public func previews(of sessionID: String) throws -> [PiPreview] {
    try select(PiPreview.self, where: "sessionID = ?", [sessionID], orderBy: "createdAt, id")
  }

  /// 按 id 取几份预览（Cue 点名的图，`CueMessage.shots`）；不在了的不在结果里。
  public func previews(_ ids: some Collection<UUID>) throws -> [UUID: PiPreview] {
    guard !ids.isEmpty else { return [:] }
    let found = try select(PiPreview.self, where: "id IN (SELECT value FROM json_each(?))", [Self.idList(ids)])
    return Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
  }
}

extension PiPreviewAdded {
  /// 页面里 `<link href>`（样式、图标）与 `<script|img|source|video|audio|iframe src>` 指向的不是 data:、blob:、页内锚点的地址，按出现的先后、去重。
  /// 先去掉内联脚本的正文：脚本里拼出来的标签（`'<img src="' + x + '">'`）不是页面引用的文件。
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
