import Foundation
#if os(macOS)
import Security
#endif

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
/// - macOS：`~/Library/Application Support/CuePad/Library/`；
/// - iOS：App Group `group.com.sugeh.cuepad` 共享容器下的 `Library/`（分享扩展、小组件与主 App 共用）；
/// - 环境变量 `CUEPAD_LIBRARY_DIR`（绝对路径）指向隔离目录，各平台通用。
/// Mac 上只有正式版（Developer ID 签名的 App 与随它分发的命令行）打开真实资料库：本机构建的代码一打开就会就地升级库结构、改写数据，
/// 装着的正式版之后就打不开它了，还会把改动同步出去（日常构建、测量构建、自己编的命令行都误开过）。所以没给环境变量的本机构建
/// （Xcode 里 ⌘R、双击产物、自己编的命令行）打开自己的开发库 `~/Library/Application Support/CuePad Dev/Library/`，按隔离库对待；
/// 克隆下来的人不用先配环境变量就能跑。iOS 真机的开发构建本来就要用真机上的库，不受限。
/// 这里只定库放哪：碰不碰这台设备上的真实世界（各家 Agent 的配置、通知……）是另一件事，由 App 层按 `origin` 定（`touchesRealWorld`）。
/// 偏好、待处理内容、快照等其他放在库目录里的东西由 App 层自己定名。
public struct LibraryLocation: Equatable, Sendable {
  public static let environmentKey = "CUEPAD_LIBRARY_DIR"
  public static let appGroupIdentifier = "group.com.sugeh.cuepad"

  public enum Base: Sendable {
    /// macOS：应用支持目录。
    case applicationSupport(URL)
    /// iOS：App Group 共享容器；没有权限时为 nil。
    case appGroup(container: URL?)

    public static var platform: Base {
      #if os(iOS)
      .appGroup(container: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: LibraryLocation.appGroupIdentifier))
      #else
      .applicationSupport(URL.applicationSupportDirectory)
      #endif
    }
  }

  /// 库是怎么定下来的。
  public enum Origin: Sendable {
    /// 正式版的真实库（Mac 上 Developer ID 签名的进程，iOS 上 App Group 里的）
    case release
    /// Mac 本机构建的开发库（`CuePad Dev`）
    case development
    /// 环境变量或调用方指定的隔离目录（xc.sh、测试、临时库）
    case override
  }

  public let directory: URL
  public let origin: Origin
  /// 是不是隔离库（不是正式版那份）：偏好与缓存放进库目录，不连 iCloud。
  public var isIsolated: Bool { origin != .release }

  public var databaseURL: URL { directory.appending(path: "cuepad.db") }

  /// 可随时重建的缓存（交付物按文件名放的一份、缩略图与网页快照）：真实库在系统的缓存目录（系统可清、不进备份），
  /// 隔离库在隔离目录的 `Caches/` 里——本机构建、测量与测试不往正式版的缓存里写。
  public var caches: URL { isIsolated ? directory.appending(path: "Caches", directoryHint: .isDirectory) : URL.cachesDirectory }

  /// 指向一个隔离目录（同 `CUEPAD_LIBRARY_DIR`）：测试、临时库用。
  public static func isolated(_ directory: URL) -> LibraryLocation {
    LibraryLocation(directory: directory, origin: .override)
  }

  public static func resolve(
    environment: [String: String] = ProcessInfo.processInfo.environment, base: Base = .platform
  ) throws -> LibraryLocation {
    if let override = environment[environmentKey], !override.isEmpty {
      guard override.hasPrefix("/") else { throw LibraryLocationError.relativePath(override) }
      return .isolated(URL(filePath: override, directoryHint: .isDirectory))
    }
    switch base {
    case .appGroup(let container):
      guard let container else { throw LibraryLocationError.appGroupUnavailable(appGroupIdentifier) }
      return LibraryLocation(directory: container.appending(path: "Library", directoryHint: .isDirectory), origin: .release)
    case .applicationSupport(let support):
      #if os(macOS)
      if support == URL.applicationSupportDirectory, !isReleaseSigned {
        return LibraryLocation(directory: support.appending(path: "CuePad Dev/Library", directoryHint: .isDirectory), origin: .development)
      }
      #endif
      return LibraryLocation(directory: support.appending(path: "CuePad/Library", directoryHint: .isDirectory), origin: .release)
    }
  }

  #if os(macOS)
  /// 本进程是不是 Developer ID 签名（公证发布的正式版）。ad-hoc、未签名与 Apple Development 签名的本机构建都不是。
  public static let isReleaseSigned: Bool = {
    var code: SecCode?
    var staticCode: SecStaticCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code, SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
    else { return false }
    return isDeveloperID(staticCode)
  }()

  /// 这个 App 包是不是 Developer ID 签名：同上，看别的副本（`touchesRealWorld` 找这台装没装正式版）。
  public static func isReleaseSigned(at bundle: URL) -> Bool {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return false }
    return isDeveloperID(staticCode)
  }

  /// 签名证书链第一张的名字以 "Developer ID Application" 开头。只读签名信息、不校验：这里分的是正式版与本机构建，不是防伪。
  private static func isDeveloperID(_ code: SecStaticCode) -> Bool {
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
      let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
      let leaf = certificates.first,
      let name = SecCertificateCopySubjectSummary(leaf) as String?
    else { return false }
    return name.hasPrefix("Developer ID Application")
  }
  #endif
}
