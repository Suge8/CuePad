import CueStore
import Foundation
import Testing

@Suite struct LibraryLocationTests {

  static let cases: [([String: String], LibraryLocation.Base, Bool, String, Bool)] = {
    var cases: [([String: String], LibraryLocation.Base, Bool, String, Bool)] = [
      (["CUEPAD_LIBRARY_DIR": "/tmp/cuepad-isolated"], .applicationSupport(URL(filePath: "/x")), true, "/tmp/cuepad-isolated", true),
      (["CUEPAD_LIBRARY_DIR": "/tmp/iso"], .appGroup(container: nil), false, "/tmp/iso", true),
      (["CUEPAD_LIBRARY_DIR": ""], .applicationSupport(URL(filePath: "/support")), true, "/support/CuePad/Library", false),
      ([:], .appGroup(container: URL(filePath: "/group")), false, "/group/Library", false),
    ]
    #if os(macOS)
    cases.append(([:], .applicationSupport(URL(filePath: "/support")), false, "/support/CuePad Dev/Library", true))
    #endif
    return cases
  }()

  @Test(arguments: cases)
  func locationFollowsPlatformAndOverride(environment: [String: String], base: LibraryLocation.Base, release: Bool, directory: String, isolated: Bool) throws {
    let location = try LibraryLocation.resolve(environment: environment, base: base, isRelease: release)
    #expect(location.directory.path == directory && location.isIsolated == isolated)
    #expect(location.databaseURL.path == directory + "/cuepad.db")
  }
}
