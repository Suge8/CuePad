#if os(macOS) && DEBUG
import AppKit

/// 占前台的唯一入口：本机构建一律在后台（`DebugHooks.present`），只有启动参数给了 `-CuePadForeground YES` 且用户不在才借得到
/// （启动时查，`requireUserAway`：不够空闲就报读数、退出码 2，调用方的命令随之失败；别的借法与重试都绕不开它）。
/// 借时记下当时的前台应用，动过指针就记下原位，`giveBack` 时都还回去；量完、被结束都经应用终止流程还（`DebugHooks.willTerminate`），
/// 被 KILL 时系统把前台交给下一个应用，指针不还。哪几样可以借、什么时候才可以给见 docs/verify.md「占前台」。
/// 系统的激活是协商式的：别的应用在前台时 `NSApp.activate()` 会被忽略，窗口照旧在后面、点一下只是激活。所以借着而没在前台时
/// 写下请求文件（`CUEPAD_FRONT_REQUEST`，起实例的 app.py 给），看守进程见到它就替本进程拉到前台；到了前台就删掉，被抢走再写。
enum DebugForeground {
    private static var lender: NSRunningApplication?
    private static var pointer: CGPoint?
    private static var holding = false
    private static let request = ProcessInfo.processInfo.environment["CUEPAD_FRONT_REQUEST"]

    /// 键鼠静止多久才算用户不在。前台测量独占全机、会移指针与抢键盘，几十秒的"借一下"在用户眼前就是打断；
    /// 5 分钟排除了读屏、思考与等编译的间隙，也低于锁屏、睡眠等常见的离开。
    private static let awayAfter: TimeInterval = 300

    /// 启动时：给了 `-CuePadForeground YES` 而用户不够空闲，就报读数、以 2 退出（起实例的 xc.sh 命令随之失败，原因在实例日志末尾）。
    /// 只在启动时查：借着的时候自己发的 HID 事件也会清零空闲时长。
    static func requireUserAway() {
        guard DebugScene.defaults.bool(forKey: "CuePadForeground") else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < awayAfter else { return }
        FileHandle.standardError.write(Data("用户 \(Int(idle)) 秒前还在操作（键鼠空闲不足 \(Int(awayAfter)) 秒），不借前台：等用户离开，或改用后台量（去掉 -CuePadForeground YES）\n".utf8))
        exit(2)
    }

    /// 本 App 到前台、`window` 到最前并接过键盘；没给 `-CuePadForeground YES` 时什么都不做，返回 false。可重复调（把窗口再拉到最前）。
    static func borrow(_ window: NSWindow) -> Bool {
        guard DebugScene.defaults.bool(forKey: "CuePadForeground") else { return false }
        if lender == nil, let front = NSWorkspace.shared.frontmostApplication, front != .current { lender = front }
        holding = true
        _ = watching
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        askFront(!NSApp.isActive)
        return true
    }

    /// 非占前台不可的（`what` 说是谁）：借不到就报错退出。
    static func require(_ window: NSWindow, for what: String) {
        guard !borrow(window) else { return }
        FileHandle.standardError.write(Data("\(what) 要占前台：加 -CuePadForeground YES（docs/verify.md「占前台」）\n".utf8))
        exit(2)
    }

    /// 把真实指针移到 `point`（全局坐标，主屏左上为原点）；第一次移时记下原位，`giveBack` 时放回。只在借到前台后调。
    static func movePointer(to point: CGPoint) {
        if pointer == nil { pointer = CGEvent(source: nil)?.location }
        CGWarpMouseCursorPosition(point)
    }

    /// 还前台与指针：窗口排回最后，借前的前台应用回到前台，动过的指针回原位。没借过时什么都不做。
    static func giveBack() {
        holding = false
        askFront(false)
        if let pointer { CGWarpMouseCursorPosition(pointer) }
        pointer = nil
        guard let lender else { return }
        self.lender = nil
        NSApp.windows.forEach { $0.orderBack(nil) }
        NSApp.yieldActivation(to: lender)
        lender.activate(from: .current)
    }

    /// 借着时：到了前台撤下请求，被别的应用抢走再请求（第一次借时装上，之后一直在）。
    private static let watching: Void = {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { askFront(false) }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { askFront(holding) }
        }
    }()

    private static func askFront(_ wanted: Bool) {
        guard let request else { return }
        if wanted {
            FileManager.default.createFile(atPath: request, contents: nil)
        } else {
            do {
                try FileManager.default.removeItem(atPath: request)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // 脚本已经收走
            } catch {
                DebugScene.abandon("要前台的请求文件删不掉", error)
            }
        }
    }
}
#endif
