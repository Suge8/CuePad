import Foundation

public enum LibraryLocationError: Error, Equatable, LocalizedError {
  case relativePath(key: String, value: String)
  case appGroupUnavailable(String)

  public var errorDescription: String? {
    switch self {
    case .relativePath(let key, let value): String(localized: "\(key) 必须是绝对路径，收到「\(value)」")
    case .appGroupUnavailable(let id): String(localized: "无法访问共享容器 \(id)：App 没有该 App Group 的权限（真机需要开发者签名）")
    }
  }
}

/// 资料库的位置（唯一规则）。库文件 `cuepad.db` 在 `directory` 下，附件目录由 `CueStore.files` 管。环境变量 `CUEPAD_LIBRARY_DIR`（绝对路径）指向隔离目录，各平台通用。
/// Mac 上只有正式版（发版脚本归档的 App 与随它分发的命令行，`AppIdentity.isRelease`）打开真实资料库：本机构建的代码一打开就会就地升级库结构、改写数据，
/// 装着的正式版之后就打不开它了，还会把改动同步出去（日常构建、测量构建、自己编的命令行都误开过）。所以没给环境变量的本机构建
/// （Xcode 里 ⌘R、双击产物、自己编的命令行）打开自己的开发库 `~/Library/Application Support/CuePad Dev/Library/`，按隔离库对待；
/// 克隆下来的人不用先配环境变量就能跑。iOS 真机的开发构建本来就要用真机上的库，不受限。
/// 这里只定库放哪：碰不碰这台设备上的真实世界（各家 Agent 的配置、通知……）是另一件事，由 App 层按 `origin` 定（`touchesRealWorld`）。
public struct LibraryLocation: Equatable, Sendable {
  public static let environmentKey = "CUEPAD_LIBRARY_DIR"

  public enum Base: Sendable {
    case applicationSupport(URL)
    case appGroup(container: URL?)

    public static var platform: Base {
      #if os(iOS)
      .appGroup(container: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppIdentity.appGroup))
      #else
      .applicationSupport(URL.applicationSupportDirectory)
      #endif
    }
  }

  public enum Origin: Sendable {
    case release
    case development
    case override
  }

  public let directory: URL
  public let origin: Origin
  public var isIsolated: Bool { origin != .release }

  public var databaseURL: URL { directory.appending(path: "cuepad.db") }

  public var caches: URL {
    #if os(macOS)
    if !isIsolated { return URL.cachesDirectory }
    #endif
    return directory.appending(path: "Caches", directoryHint: .isDirectory)
  }

  public static let deviceLogsKey = "CUEPAD_DEVICE_LOGS_DIR"

  /// 各台设备经 iCloud 送到这台 Mac 的诊断落在哪（App 的 `DiagnosticInbox`）：正式版在 macOS 放应用日志的地方（~/Library/Logs/CuePad），
  /// 不进资料库目录，agent 读它不碰资料库。环境变量 `CUEPAD_DEVICE_LOGS_DIR`（绝对路径）换掉它（`xc.sh` 的隔离实例给库里的 `Logs/`，`app_env.py` 的 `isolated_env`）；
  /// 没给时隔离库也放自己目录的 `Logs/`，不往正式版那里写。
  public func deviceLogs(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
    if let override = try Self.overrideDirectory(Self.deviceLogsKey, in: environment) { return override }
    return isIsolated
      ? directory.appending(path: "Logs", directoryHint: .isDirectory) : UserHome.directory.appending(path: "Library/Logs/CuePad", directoryHint: .isDirectory)
  }

  public static func overrideDirectory(_ key: String, in environment: [String: String]) throws -> URL? {
    guard let value = environment[key], !value.isEmpty else { return nil }
    guard value.hasPrefix("/") else { throw LibraryLocationError.relativePath(key: key, value: value) }
    return URL(filePath: value, directoryHint: .isDirectory)
  }

  public static func isolated(_ directory: URL) -> LibraryLocation {
    LibraryLocation(directory: directory, origin: .override)
  }

  public static func resolve(
    environment: [String: String] = ProcessInfo.processInfo.environment, base: Base = .platform, isRelease: Bool? = nil
  ) throws -> LibraryLocation {
    if let override = try overrideDirectory(environmentKey, in: environment) { return .isolated(override) }
    switch base {
    case .appGroup(let container):
      guard let container else { throw LibraryLocationError.appGroupUnavailable(AppIdentity.appGroup) }
      return LibraryLocation(directory: container.appending(path: "Library", directoryHint: .isDirectory), origin: .release)
    case .applicationSupport(let support):
      #if os(macOS)
      if !(isRelease ?? AppIdentity.isRelease) {
        return LibraryLocation(directory: support.appending(path: "CuePad Dev/Library", directoryHint: .isDirectory), origin: .development)
      }
      #endif
      return LibraryLocation(directory: support.appending(path: "CuePad/Library", directoryHint: .isDirectory), origin: .release)
    }
  }
}
