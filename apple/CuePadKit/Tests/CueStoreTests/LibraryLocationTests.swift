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

  @Test func absoluteOverrideIsUsedVerbatim() throws {
    let location = try LibraryLocation.resolve(
      environment: ["CUEPAD_LIBRARY_DIR": "/tmp/cuepad-isolated"], base: .applicationSupport(URL(filePath: "/x")))
    #expect(location.directory.path == "/tmp/cuepad-isolated")
    #expect(location.isIsolated)
    #expect(location.databaseURL.path == "/tmp/cuepad-isolated/cuepad.db")
  }

  @Test func emptyOverrideCountsAsUnset() throws {
    let location = try LibraryLocation.resolve(environment: ["CUEPAD_LIBRARY_DIR": ""], base: .applicationSupport(URL(filePath: "/support")))
    #expect(location.directory.path == "/support/CuePad/Library" && !location.isIsolated)
  }

  @Test func macLibraryLivesInApplicationSupport() throws {
    let location = try LibraryLocation.resolve(environment: [:], base: .applicationSupport(URL(filePath: "/support")))
    #expect(location.directory.path == "/support/CuePad/Library")
    #expect(location.databaseURL.path == "/support/CuePad/Library/cuepad.db")
  }

  @Test func iOSLibraryLivesInTheAppGroupContainer() throws {
    let location = try LibraryLocation.resolve(environment: [:], base: .appGroup(container: URL(filePath: "/group")))
    #expect(location.directory.path == "/group/Library")
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

  @Test func overrideWinsOnEveryPlatform() throws {
    let location = try LibraryLocation.resolve(environment: ["CUEPAD_LIBRARY_DIR": "/tmp/iso"], base: .appGroup(container: nil))
    #expect(location.directory.path == "/tmp/iso")
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
