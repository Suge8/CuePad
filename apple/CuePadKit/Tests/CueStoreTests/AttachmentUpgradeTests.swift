import CryptoKit
import CueStore
import Foundation
import Testing

/// 升级到按键存取的附件（结构 77）：旧引用 `cuepad://img/<哈希>`、旧记录（非图片写 "bin"）与库旁以哈希为名的旧文件改到新写法；
/// 推得出扩展名的行版本加 1 毫秒（照常上传、服务器收敛），推不出的只在本机改。
@Suite struct AttachmentUpgradeTests {
  let directory = TestLibraries.makeDirectory()
  var db: RawDB { RawDB(directory.appending(path: "cuepad.db")) }
  var old: URL { directory.appending(path: "Attachments", directoryHint: .isDirectory) }
  var cached: URL { directory.appending(path: "Caches/CuePadAttachments", directoryHint: .isDirectory) }

  private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
  private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  @Test func legacyReferencesRecordsAndFilesMoveToKeys() async throws {
    _ = try CueStore(location: .isolated(directory))
    let png = pngData(width: 6, height: 6), movie = Data("not really a movie".utf8)
    let unrecorded = pngData(width: 3, height: 3)
    let photo = sha256(png), clip = sha256(movie), gone = String(repeating: "e", count: 64), orphan = sha256(unrecorded)
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try png.write(to: old.appending(path: photo))
    try movie.write(to: old.appending(path: clip))
    try unrecorded.write(to: old.appending(path: orphan))  // 被引用、文件在本机，却没有附件记录
    try db.exec(
      """
      INSERT INTO cards (id, projectID, body, isPinned, variableValues, sortKey, createdAt, modifiedAt)
        VALUES ('00000000-0000-4000-8000-0000000000c1', '\(Project.defaultID.uuidString.lowercased())', '看 ![](cuepad://img/\(photo)) 这张', 0, '{}', 'a', 1, 1000),
               ('00000000-0000-4000-8000-0000000000c2', '\(Project.defaultID.uuidString.lowercased())', '丢了 ![](cuepad://img/\(gone))', 0, '{}', 'b', 1, 2000),
               ('00000000-0000-4000-8000-0000000000c3', '\(Project.defaultID.uuidString.lowercased())', '没登记 ![](cuepad://img/\(orphan))', 0, '{}', 'c', 1, 3000);
      INSERT INTO attachments (id, hash, byteCount, format, createdAt, modifiedAt) VALUES
        ('00000000-0000-4000-8000-0000000000a1', '\(photo)', \(png.count), 'png', 1, 10), ('00000000-0000-4000-8000-0000000000a2', '\(clip)', \(movie.count), 'bin', 1, 20);
      INSERT INTO syncRecords (recordName, recordType, pushedModifiedAt) VALUES ('00000000-0000-4000-8000-0000000000a1', 'attachments', 10), ('00000000-0000-4000-8000-0000000000a2', 'attachments', NULL);
      INSERT INTO previews (id, sessionID, hash, name, title, byteCount, createdAt, modifiedAt) VALUES ('00000000-0000-4000-8000-0000000000b1', 's', '\(clip)', '演示.MOV', '演示', \(movie.count), 1, 1);
      PRAGMA user_version = 76;
      """)

    let store = try CueStore(location: .isolated(directory))

    #expect(try db.rows("SELECT id, body, modifiedAt FROM cards ORDER BY id") == [
      ["00000000-0000-4000-8000-0000000000c1", "看 ![](cuepad://file/\(photo).png) 这张", "1001"],
      ["00000000-0000-4000-8000-0000000000c2", "丢了 ![](cuepad://file/\(gone))", "2000"],  // 这台推不出扩展名：只在本机改，不上传
      ["00000000-0000-4000-8000-0000000000c3", "没登记 ![](cuepad://file/\(orphan).png)", "3001"],
    ])
    #expect(try db.rows("SELECT id, format, modifiedAt FROM attachments WHERE hash != '\(orphan)' ORDER BY id") == [["00000000-0000-4000-8000-0000000000a1", "png", "10"], ["00000000-0000-4000-8000-0000000000a2", "mov", "21"]])
    #expect(try db.rows("SELECT format, byteCount FROM attachments WHERE hash = '\(orphan)'") == [["png", "\(unrecorded.count)"]])  // 补登记，照常上传
    #expect(try Data(contentsOf: #require(store.files.fileURL(for: photo + ".png"))) == png)
    #expect(try Data(contentsOf: #require(store.files.fileURL(for: clip + ".mov"))) == movie)
    #expect(try await store.previews(of: "s").map(\.key) == [clip + ".mov"])
    // 服务器收下过的不留保底，没收下的按新键留；旧名都不在了
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: old.path)) == [clip + ".mov", orphan + ".png"])
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: cached.path)) == [photo + ".png", clip + ".mov", orphan + ".png"])
  }
}
