import CueStore
import Foundation
import SQLite3
import Testing

@testable import CueCLI

/// 临时目录里的隔离资料库；每次调用都显式带 CUEPAD_LIBRARY_DIR，绝不落到用户的真实库。
final class Sandbox: @unchecked Sendable {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "cuepad-cli-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
  let store: CueStore

  init() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    store = try CueStore(url: directory.appending(path: "cuepad.db"))
  }

  deinit { try? FileManager.default.removeItem(at: directory) }

  func run(_ arguments: String..., stdin: String? = nil) async -> CLIResult {
    await CLI.run(arguments, environment: ["CUEPAD_LIBRARY_DIR": directory.path], stdin: { stdin })
  }

  /// 期望成功并解析 stdout 的 JSON。
  func json(_ arguments: String..., stdin: String? = nil) async throws -> Any {
    let result = await CLI.run(
      arguments + ["--json"], environment: ["CUEPAD_LIBRARY_DIR": directory.path], stdin: { stdin })
    #expect(result.code == 0, "\(arguments) → \(result.err)")
    return try JSONSerialization.jsonObject(with: Data(result.out.utf8))
  }

  func object(_ arguments: String..., stdin: String? = nil) async throws -> [String: Any] {
    let result = await CLI.run(
      arguments + ["--json"], environment: ["CUEPAD_LIBRARY_DIR": directory.path], stdin: { stdin })
    #expect(result.code == 0, "\(arguments) → \(result.err)")
    return try #require(JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any])
  }

  func project(_ name: String) async throws -> Project {
    try await store.createProject(name: name, color: "blue")
  }

  /// 绕过 Store 造出同步才会产生的冲突副本。
  func markConflict(copy: UUID, of original: UUID) throws {
    var handle: OpaquePointer?
    defer { sqlite3_close(handle) }
    #expect(sqlite3_open(directory.appending(path: "cuepad.db").path, &handle) == SQLITE_OK)
    let sql = "UPDATE cards SET conflictOf = '\(original.uuidString)' WHERE id = '\(copy.uuidString)'"
    #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
  }
}

extension Dictionary where Key == String, Value == Any {
  func string(_ key: String) -> String? { self[key] as? String }
}

func array(_ value: Any) throws -> [[String: Any]] {
  try #require(value as? [[String: Any]])
}
