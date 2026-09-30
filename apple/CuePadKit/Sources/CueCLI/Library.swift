import CueStore
import Foundation

/// 资料库位置：与 App 的 `LibraryLocation.resolve` 同规则。
/// 临时实现：CueStore 提供位置的唯一事实源（含 CUEPAD_LIBRARY_DIR）后整个文件删除，改调 CueStore。
enum Library {
  static let isolationKey = "CUEPAD_LIBRARY_DIR"

  static func open(environment: [String: String]) throws -> CueStore {
    let url = try databaseURL(environment: environment)
    do { return try CueStore(url: url) } catch {
      throw CLIError(kind: .store, message: "无法打开资料库 \(url.path)：\(error)")
    }
  }

  /// 隔离目录按需创建（同 App）；真实库必须已由 App 建好，CLI 不凭空造一个。
  private static func databaseURL(environment: [String: String]) throws -> URL {
    if let override = environment[isolationKey], !override.isEmpty {
      guard override.hasPrefix("/") else {
        throw CLIError.invalid("\(isolationKey) 必须是绝对路径，收到「\(override)」")
      }
      return URL(filePath: override, directoryHint: .isDirectory).appending(path: "cuepad.db")
    }
    let url = URL.applicationSupportDirectory.appending(path: "CuePad/Library/cuepad.db")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw CLIError(
        kind: .noLibrary,
        message: "找不到 CuePad 资料库（\(url.path)）：先打开一次 CuePad.app，或用 \(isolationKey) 指向隔离目录")
    }
    return url
  }
}
