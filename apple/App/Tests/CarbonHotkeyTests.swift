#if os(macOS)
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct CarbonHotkeyTests {
    private let rare = Shortcut(keyCode: 80, modifiers: [.command, .option, .control, .shift])

    @Test func 同进程重复注册报占用_释放后可再注册() throws {
        let backend = CarbonHotkeyBackend()
        let handle = try backend.register(rare) {}

        #expect(throws: HotkeyError.occupied(rare)) { try backend.register(rare) {} }

        backend.unregister(handle)
        backend.unregister(try backend.register(rare) {})
    }
}
#endif
