import CueStore
import Foundation
import Testing

@Suite struct LibraryLocationTests {

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
}
