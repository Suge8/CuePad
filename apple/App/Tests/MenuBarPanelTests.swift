#if os(macOS)
import Foundation
import Testing
@testable import CuePad

struct MenuBarPanelPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let size = CGSize(width: 300, height: 200)

    @Test(arguments: [5.0, 1420.0])
    func 图标靠近屏幕边缘时面板不越界(iconX: Double) {
        let icon = CGRect(x: iconX, y: 875, width: 30, height: 25)
        let frame = CGRect(origin: MenuBarPanel.origin(for: size, below: icon, in: screen), size: size)
        #expect(screen.contains(frame))
    }
}
#endif
