#if os(macOS)
import CueStore
@_exported import CueTestSupport
import Foundation
import Testing

@testable import CueCLI

/// 命令行用例的库是 `Fixture` 的隔离目录：每次调用都显式带 CUEPAD_LIBRARY_DIR，绝不落到用户的真实库。
extension Fixture {
  /// 默认在库目录里运行：它不绑定任何项目。`cwd` 模拟从某个目录调用。
  func call(_ arguments: [String], stdin: String? = nil, cwd: String? = nil, environment: [String: String] = [:]) async -> CLIResult {
    await CLI.run(
      arguments, environment: ["CUEPAD_LIBRARY_DIR": directory.path].merging(environment) { $1 }, directory: cwd ?? directory.path,
      stdin: { stdin })
  }

  func run(_ arguments: String..., stdin: String? = nil, cwd: String? = nil, environment: [String: String] = [:]) async -> CLIResult {
    await call(arguments, stdin: stdin, cwd: cwd, environment: environment)
  }

  func json(_ arguments: String..., stdin: String? = nil, cwd: String? = nil) async throws -> Any {
    try await jsonValue(arguments, stdin: stdin, cwd: cwd)
  }

  func object(_ arguments: String..., stdin: String? = nil, cwd: String? = nil, environment: [String: String] = [:]) async throws -> [String: Any] {
    try #require(try await jsonValue(arguments, stdin: stdin, cwd: cwd, environment: environment) as? [String: Any])
  }

  func jsonValue(_ arguments: [String], stdin: String? = nil, cwd: String? = nil, environment: [String: String] = [:]) async throws -> Any {
    let result = await call(arguments + ["--json"], stdin: stdin, cwd: cwd, environment: environment)
    #expect(result.code == 0, "\(arguments) → \(result.err)")
    return try JSONSerialization.jsonObject(with: Data(result.out.utf8))
  }

  func project(_ name: String) async throws -> Project {
    try await store.createProject(name: name, color: "blue")
  }

  /// 绕过 Store 造出同步才会产生的冲突副本。
  func markConflict(copy: UUID, of original: UUID) throws {
    try RawDB(url).exec("UPDATE cards SET conflictOf = '\(original.uuidString.lowercased())' WHERE id = '\(copy.uuidString.lowercased())'")
  }

  /// 把一条卡片的 id 改成指定值（UUID 是随机的，造不出共用前缀的两条）。
  func assignID(_ id: UUID, _ new: String) throws {
    try RawDB(url).exec("UPDATE cards SET id = '\(new)' WHERE id = '\(id.uuidString.lowercased())'")
  }
}

/// 构建出来的 `cuepad`：SwiftPM 把它与测试包放在同一个产物目录；没构建出来就停在这里。
func cuepadBinary() throws -> URL {
  let binary = Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appending(path: "cuepad")
  try #require(FileManager.default.isExecutableFile(atPath: binary.path), "先构建 cuepad 产物：\(binary.path)")
  return binary
}

private final class Anchor {}

extension Dictionary where Key == String, Value == Any {
  func string(_ key: String) -> String? { self[key] as? String }
}

func array(_ value: Any) throws -> [[String: Any]] {
  try #require(value as? [[String: Any]])
}
#endif
