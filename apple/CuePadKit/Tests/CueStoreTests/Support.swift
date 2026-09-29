import CueStore
import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers
import Testing

/// 临时目录里的真实库文件；释放时清理。
final class Fixture: @unchecked Sendable {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "cuepad-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  var url: URL { directory.appending(path: "cuepad.db") }
  let store: CueStore

  init() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    store = try CueStore(url: directory.appending(path: "cuepad.db"))
  }

  deinit { try? FileManager.default.removeItem(at: directory) }
}

/// 用独立的 sqlite3 连接直接读写库文件：构造并发场景、检查落盘格式与旧库 fixture。
struct RawDB {
  let path: String

  init(_ url: URL) { path = url.path }

  func exec(_ sql: String) throws {
    var handle: OpaquePointer?
    defer { sqlite3_close(handle) }
    guard sqlite3_open(path, &handle) == SQLITE_OK else { throw RawError(message: "open") }
    sqlite3_busy_timeout(handle, 5000)
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
      throw RawError(message: String(cString: sqlite3_errmsg(handle)))
    }
  }

  /// 每行每列按文本读出（NULL 为 "NULL"）。
  func rows(_ sql: String) throws -> [[String]] {
    var handle: OpaquePointer?
    defer { sqlite3_close(handle) }
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      throw RawError(message: "open")
    }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
      throw RawError(message: String(cString: sqlite3_errmsg(handle)))
    }
    defer { sqlite3_finalize(statement) }
    var result: [[String]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      result.append(
        (0..<sqlite3_column_count(statement)).map { column in
          sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "NULL"
        })
    }
    return result
  }

  func count(_ table: String) throws -> Int { Int(try rows("SELECT count(*) FROM \(table)")[0][0])! }
}

struct RawError: Error { let message: String }

func bodies(_ cards: [Card]) -> [String] { cards.map(\.body) }

func sameInstant(_ a: Date?, _ b: Date, sourceLocation: SourceLocation = #_sourceLocation) {
  guard let a else {
    Issue.record("date is nil", sourceLocation: sourceLocation)
    return
  }
  #expect(abs(a.timeIntervalSince(b)) < 0.002, sourceLocation: sourceLocation)
}

/// 纯色 PNG；`shade` 不同则字节不同。
func pngData(width: Int, height: Int, shade: CGFloat = 0.5) -> Data {
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(red: shade, green: 0.2, blue: 0.8, alpha: 1)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let data = NSMutableData()
  let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination, context.makeImage()!, nil)
  CGImageDestinationFinalize(destination)
  return data as Data
}
