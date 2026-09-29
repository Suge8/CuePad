#if os(macOS)
import Foundation
import Testing
@testable import CuePad

struct MenuBarPanelPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 300, height: 200)

    @Test func 面板在图标正下方居中() {
        let icon = CGRect(x: 1000, y: 875, width: 30, height: 25)
        let origin = MenuBarPanel.origin(for: size, below: icon, in: screen)
        #expect(origin.x == 1015 - 150)
        #expect(origin.y + size.height <= icon.minY)
    }

    @Test(arguments: [5.0, 1420.0])
    func 图标靠近屏幕边缘时面板不越界(iconX: Double) {
        let icon = CGRect(x: iconX, y: 875, width: 30, height: 25)
        let frame = CGRect(origin: MenuBarPanel.origin(for: size, below: icon, in: screen), size: size)
        #expect(screen.contains(frame))
    }
}
#endif
