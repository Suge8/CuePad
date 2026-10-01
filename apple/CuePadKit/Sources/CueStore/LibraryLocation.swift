import Foundation

public enum LibraryLocationError: Error, Equatable, LocalizedError {
  case relativePath(String)
  case appGroupUnavailable(String)

  public var errorDescription: String? {
    switch self {
    case .relativePath(let value): "CUEPAD_LIBRARY_DIR 必须是绝对路径，收到「\(value)」"
    case .appGroupUnavailable(let id): "无法访问共享容器 \(id)：App 没有该 App Group 的权限（真机需要开发者签名）"
    }
  }
}

/// 资料库的位置（唯一规则）。库文件 `cuepad.db` 在 `directory` 下，附件目录由 `CueStore.files` 管。
/// - macOS：`~/Library/Application Support/CuePad/Library/`，并指向 Electron 版数据库以便导入；
/// - iOS：App Group `group.com.sugeh.cuepad` 共享容器下的 `Library/`（分享扩展、小组件与主 App 共用）；
/// - 环境变量 `CUEPAD_LIBRARY_DIR`（绝对路径）指向隔离目录，各平台通用，不导入旧库。
/// 偏好、待处理内容、快照等其他放在库目录里的东西由 App 层自己定名。
public struct LibraryLocation: Equatable, Sendable {
  public static let environmentKey = "CUEPAD_LIBRARY_DIR"
  public static let appGroupIdentifier = "group.com.sugeh.cuepad"

  /// 位置所依附的平台存储。
  public enum Base: Sendable {
    /// macOS：应用支持目录。
    case applicationSupport(URL)
    /// iOS：App Group 共享容器；没有权限时为 nil。
    case appGroup(container: URL?)

    /// 当前平台的存储。
    public static var platform: Base {
      #if os(iOS)
      .appGroup(container: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LibraryLocation.appGroupIdentifier))
      #else
      .applicationSupport(URL.applicationSupportDirectory)
      #endif
    }
  }

  public let directory: URL
  /// Electron 版数据库；只有 macOS 的默认位置有，且可能不存在。
  public let electronDatabase: URL?
  /// 是否由环境变量指向隔离目录。
  public let isIsolated: Bool

  public var databaseURL: URL { directory.appending(path: "cuepad.db") }

  public static func resolve(
    environment: [String: String] = ProcessInfo.processInfo.environment, base: Base = .platform
  ) throws -> LibraryLocation {
    if let override = environment[environmentKey], !override.isEmpty {
      guard override.hasPrefix("/") else { throw LibraryLocationError.relativePath(override) }
      return LibraryLocation(
        directory: URL(filePath: override, directoryHint: .isDirectory), electronDatabase: nil, isIsolated: true)
    }
    switch base {
    case .appGroup(let container):
      guard let container else { throw LibraryLocationError.appGroupUnavailable(appGroupIdentifier) }
      return LibraryLocation(
        directory: container.appending(path: "Library", directoryHint: .isDirectory), electronDatabase: nil,
        isIsolated: false)
    case .applicationSupport(let support):
      return LibraryLocation(
        directory: support.appending(path: "CuePad/Library", directoryHint: .isDirectory),
        electronDatabase: support.appending(path: "CuePad/cuepad.db"), isIsolated: false)
    }
  }
}
