import CueStore
import Foundation
import Testing

/// 资料库位置的唯一规则：Mac 在应用支持目录，iOS 在 App Group 共享容器，`CUEPAD_LIBRARY_DIR` 隔离。
@Suite struct LibraryLocationTests {

  /// 位置按平台与环境变量定：Mac 在应用支持目录、iOS 在共享容器；非空的绝对路径覆盖（隔离），空值当没设。
  @Test(arguments: [
    (["CUEPAD_LIBRARY_DIR": "/tmp/cuepad-isolated"], LibraryLocation.Base.applicationSupport(URL(filePath: "/x")), "/tmp/cuepad-isolated", true),
    (["CUEPAD_LIBRARY_DIR": "/tmp/iso"], .appGroup(container: nil), "/tmp/iso", true),
    (["CUEPAD_LIBRARY_DIR": ""], .applicationSupport(URL(filePath: "/support")), "/support/CuePad/Library", false),
    ([:], .applicationSupport(URL(filePath: "/support")), "/support/CuePad/Library", false),
    ([:], .appGroup(container: URL(filePath: "/group")), "/group/Library", false),
  ] as [([String: String], LibraryLocation.Base, String, Bool)])
  func locationFollowsPlatformAndOverride(environment: [String: String], base: LibraryLocation.Base, directory: String, isolated: Bool) throws {
    let location = try LibraryLocation.resolve(environment: environment, base: base)
    #expect(location.directory.path == directory && location.isIsolated == isolated)
    #expect(location.databaseURL.path == directory + "/cuepad.db")
  }

  /// 附件与缩略图的缓存：iOS 的真实库在共享容器里（分享扩展、小组件与主 App 读写同一份），Mac 的真实库在系统缓存目录，隔离库在库目录里。
  @Test func cachesSitWhereEveryProcessOfTheLibrarySeesThem() throws {
    let group = try LibraryLocation.resolve(environment: [:], base: .appGroup(container: URL(filePath: "/group")))
    #if os(iOS)
    #expect(group.caches.path == "/group/Library/Caches")
    #else
    #expect(group.caches == URL.cachesDirectory)
    #endif
    #expect(LibraryLocation.isolated(URL(filePath: "/tmp/iso")).caches.path == "/tmp/iso/Caches")
  }
}
