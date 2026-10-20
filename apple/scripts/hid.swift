// 用法：hid click <x> <y>   在屏幕上这一点真实地点一下（全局坐标，主屏左上为原点）：指针移过去、停一会儿让悬停落定，按下、松开。
// 事件经 HID 事件流进窗口服务器，同人点：系统照真实输入调度（输入来时给的升频），App 的本地事件监听与手势照常看得到。
// 只给 perf-mac.sh 用：单次交互在前台量时 App 写 `AWAIT click x y`（`InteractionBench`），脚本收到后调它。会移动真实指针。
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4, arguments[1] == "click", let x = Double(arguments[2]), let y = Double(arguments[3]) else {
    FileHandle.standardError.write(Data("用法：hid click <x> <y>\n".utf8))
    exit(64)
}
let point = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)
func post(_ type: CGEventType) {
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}
post(.mouseMoved)
usleep(400_000)  // 悬停落定：人点之前指针早停在那一行上了
post(.leftMouseDown)
usleep(90_000)  // 同人点：按下与松开同一刻时，滚动视图里的点按手势认不出
post(.leftMouseUp)
