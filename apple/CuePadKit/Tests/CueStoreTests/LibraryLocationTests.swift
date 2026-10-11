import CueStore
import Foundation
import Testing

/// 资料库位置的唯一规则：Mac 在应用支持目录，iOS 在 App Group 共享容器，`CUEPAD_LIBRARY_DIR` 隔离。
@Suite struct LibraryLocationTests {
  @Test func relativeOverrideIsRejectedWithAReadableMessage() {
    do {
      _ = try LibraryLocation.resolve(environment: ["CUEPAD_LIBRARY_DIR": "relative/library"], base: .applicationSupport(URL(filePath: "/x")))
      Issue.record("相对路径应被拒绝")
    } catch let error as LibraryLocationError {
      #expect(error == .relativePath("relative/library"))
      #expect(error.localizedDescription.contains("CUEPAD_LIBRARY_DIR") && error.localizedDescription.contains("relative/library"))
    } catch {
      Issue.record("错误类型不对：\(error)")
    }
  }

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

  @Test func missingAppGroupEntitlementIsAReadableError() {
    do {
      _ = try LibraryLocation.resolve(environment: [:], base: .appGroup(container: nil))
      Issue.record("没有共享容器应报错")
    } catch let error as LibraryLocationError {
      #expect(error == .appGroupUnavailable("group.com.sugeh.cuepad"))
      #expect(error.localizedDescription.contains("group.com.sugeh.cuepad"))
    } catch {
      Issue.record("错误类型不对：\(error)")
    }
  }

  @Test func storeOpensTheLibraryAtItsLocation() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "cuepad-loc-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let location = try LibraryLocation.resolve(environment: ["CUEPAD_LIBRARY_DIR": directory.path], base: .applicationSupport(URL(filePath: "/x")))

    let store = try CueStore(location: location)
    _ = try await store.createCard(in: nil, body: "here")

    #expect(FileManager.default.fileExists(atPath: location.databaseURL.path))
  }
}
