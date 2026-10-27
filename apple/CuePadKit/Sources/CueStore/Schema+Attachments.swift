import CueText
import Foundation
import ImageIO

extension Schema {
  /// 78：附件换成按键存取（`AttachmentKey`、`AttachmentFiles`）。
  /// - 正文与文字里的 `![](cuepad://img/<hash>)` 改写成 `![](cuepad://file/<键>)`；
  /// - 附件记录的 format 换成键的扩展名（预览的按文件名，`PiPreview.key`；"bin" 是旧版给非图片写的）；同一份内容的几份预览文件名扩展名不同时，
  ///   多出的键各补一条记录（id 由键推出，各台补出同一行；只在文件在本机的那台补，免得传一条没文件的记录）；
  ///   被引用、文件在本机却没有记录的同样补登记；
  /// - 库旁的 `Attachments/<hash>` 按键链进缓存目录，服务器还没收下记录的留作保底（`Attachments/<键>`），旧名删掉。
  ///
  /// 每一个哈希的扩展名只由各台都有的事实推出：预览的文件名、附件记录、文件内容（ImageIO）。这样推出来的行改了就把 modifiedAt 加 1 毫秒、照常上传，
  /// 服务器才收敛到新写法，又不把修改时间刷成"刚刚"。各台都升级同一批时，写出的内容与版本号都相同：
  /// 先到服务器的那台赢，别的台按冲突规则（`applyVersion`，同刻以服务器为准）收下它，卡片正文相同就不留冲突副本。
  /// 推不出来的（这台没有记录也没有文件）只在本机改成不带扩展名的键、不加版本：推得出来的那台传上来的版本在这里会直接盖掉它。
  /// 只改了 format 的记录照常经文件那一路整条上传（`FileSender`），不另做只传字段的分支：CloudKit 对同内容的资产整文件去重，
  /// 同一份内容的另一条记录实测只传约 0.1MB，真实库里这样的 301 条（约 360MB）不会再传一遍。
  static func keyedAttachments(_ db: SQLite, _ files: AttachmentFiles) throws {
    let records = try db.query(
      """
      SELECT a.id, a.hash, a.format, a.byteCount, a.createdAt, a.modifiedAt, s.pushedModifiedAt FROM attachments a
      LEFT JOIN syncRecords s ON s.recordName = a.id ORDER BY a.id
      """
    ) { (id: $0.text(0), hash: $0.text(1), format: $0.text(2), byteCount: $0.int(3), createdAt: $0.int(4), modifiedAt: $0.int(5), pushed: !$0.isNull(6)) }
    let previews = try db.query("SELECT hash, name FROM previews ORDER BY createdAt, id") { ($0.text(0), AttachmentKey.format(ofName: $0.text(1))) }
    let recorded = Dictionary(records.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })

    var formats: [String: String] = [:]
    var previewFormats: [String: [String]] = [:]
    for (hash, format) in previews {
      if formats[hash] == nil { formats[hash] = format }
      if previewFormats[hash]?.contains(format) != true { previewFormats[hash, default: []].append(format) }
    }
    /// 这个哈希的扩展名；nil 是这台推不出来
    func format(of hash: String) -> String? {
      if let known = formats[hash] { return known }
      if let record = recorded[hash], record.format != legacyBinary { return record.format }
      let old = files.backups.appending(path: hash)
      guard FileManager.default.fileExists(atPath: old.path) else { return nil }
      let found = AttachmentFiles.imageFormat(CGImageSourceCreateWithURL(old as CFURL, nil))
      formats[hash] = found
      return found
    }

    var referenced = Set(previews.map(\.0))
    for (table, column) in [("cards", "body"), ("sendRecords", "content"), ("deliveryRequests", "content"), ("piMessages", "text"), ("cueMessages", "text")] {
      let rows = try db.query("SELECT id, \(column) FROM \(table) WHERE instr(\(column), ?) > 0", [legacyImagePrefix]) { ($0.text(0), $0.text(1)) }
      for (id, text) in rows {
        var resolved = true
        let rewritten = text.replacing(legacyImage) { match in
          let hash = String(match.output.1), found = format(of: hash)
          referenced.insert(hash)
          if found == nil { resolved = false }
          return CueFormat.imageMarkup(key: AttachmentKey.make(hash: hash, format: found ?? ""))
        }
        try db.run(
          "UPDATE \(table) SET \(column) = ?, modifiedAt = modifiedAt + ? WHERE id = ?", [rewritten, resolved ? 1 : 0, id])
      }
    }

    for record in records {
      let found = format(of: record.hash)
      if found != record.format {
        try db.run("UPDATE attachments SET format = ?, modifiedAt = modifiedAt + ? WHERE id = ?", [found ?? "", found == nil ? 0 : 1, record.id])
      }
      for extra in previewFormats[record.hash, default: []] where extra != found {
        let key = AttachmentKey.make(hash: record.hash, format: extra)
        guard FileManager.default.fileExists(atPath: files.backups.appending(path: record.hash).path) else { continue }
        try db.run(
          "INSERT OR IGNORE INTO attachments (id, hash, byteCount, format, createdAt, modifiedAt) VALUES (?, ?, ?, ?, ?, ?)",
          [DeterministicID.uuid("attachment/\(key)"), record.hash, record.byteCount, extra, record.createdAt, record.modifiedAt])
      }
    }

    // 被引用、文件在本机却没有记录的（旧版登记前就出了事）：补登记，各台补出同一行；这样才会上传，上传前留着保底
    var registered = Set(recorded.keys)
    for hash in referenced where recorded[hash] == nil {
      let old = files.backups.appending(path: hash)
      guard let size = (try? FileManager.default.attributesOfItem(atPath: old.path))?[.size] as? Int, let primary = format(of: hash) else { continue }
      let now = Date.stamp
      for format in Set([primary] + previewFormats[hash, default: []]) {
        try db.run(
          "INSERT OR IGNORE INTO attachments (id, hash, byteCount, format, createdAt, modifiedAt) VALUES (?, ?, ?, ?, ?, ?)",
          [DeterministicID.uuid("attachment/\(AttachmentKey.make(hash: hash, format: format))"), hash, size, format, now, now])
      }
      registered.insert(hash)
    }

    let pushed = Set(records.filter(\.pushed).map(\.hash))
    let old = (try? FileManager.default.contentsOfDirectory(atPath: files.backups.path)) ?? []
    for name in old where AttachmentKey.parts(name)?.format == "" {
      let source = files.backups.appending(path: name)
      let primary = format(of: name) ?? ""
      let keys = ([primary] + previewFormats[name, default: []]).map { AttachmentKey.make(hash: name, format: $0) }
      try files.adoptLegacy(source, as: Array(Set(keys)), backup: registered.contains(name) && !pushed.contains(name))
    }
  }

  /// 旧版给非图片附件写的 format
  static let legacyBinary = "bin"
  static let legacyImagePrefix = "![](cuepad://img/"
  private static var legacyImage: Regex<(Substring, Substring)> { /!\[\]\(cuepad:\/\/img\/([0-9a-f]{64})\)/ }
}

extension AttachmentFiles {
  /// 78 的那一步：库旁的旧文件（以哈希为名）链成这几个键在缓存目录里的那份，要保底的再链成 `Attachments/<键>`；旧名不再是哪个键的保底就删掉。
  func adoptLegacy(_ old: URL, as keys: [String], backup: Bool) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for key in keys {
      let cached = directory.appending(path: key)
      if !FileManager.default.fileExists(atPath: cached.path) { try FileManager.default.linkItem(at: old, to: cached) }
      if backup, key != old.lastPathComponent { try link(old, to: backups.appending(path: key)) }
    }
    if !(backup && keys.contains(old.lastPathComponent)) { try FileManager.default.removeItem(at: old) }
  }
}
