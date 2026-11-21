#if os(macOS) && DEBUG
import AppKit

/// 占前台的唯一入口：本机构建一律在后台（`DebugHooks.keepsBehind`），只有启动参数给了 `-CuePadForeground YES` 且用户不在才借得到
/// （启动时查，`requireUserAway`：不够空闲就报读数、退出码 2，调用方的命令随之失败；别的借法与重试都绕不开它）。
/// 借时记下当时的前台应用，动过指针就记下原位，`giveBack` 时都还回去；量完、被结束都经应用终止流程还（`DebugHooks.willTerminate`），被 KILL 时系统把前台交给下一个应用，指针不还。
/// 系统的激活是协商式的：别的应用在前台时 `NSApp.activate()` 会被忽略，窗口照旧在后面、点一下只是激活。所以借着而没在前台时
/// 写下请求文件（`CUEPAD_FRONT_REQUEST`，起实例的 app.py 给），看守进程见到它就替本进程拉到前台；到了前台就删掉，被抢走再写。
enum DebugForeground {
    private static var lender: NSRunningApplication?
    private static var pointer: CGPoint?
    private static var holding = false
    private static let request = ProcessInfo.processInfo.environment["CUEPAD_FRONT_REQUEST"]

    private static let awayAfter: TimeInterval = 60

    /// 启动时：给了 `-CuePadForeground YES` 而用户不够空闲，就报读数、以 2 退出（起实例的 xc.sh 命令随之失败，原因在实例日志末尾）。
    /// 只在启动时查：借着的时候自己发的 HID 事件也会清零空闲时长。
    static func requireUserAway() {
        guard DebugScene.args.driveOpts.foreground else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < awayAfter else { return }
        FileHandle.standardError.write(Data("用户 \(Int(idle)) 秒前还在操作（键鼠空闲不足 \(Int(awayAfter)) 秒），不借前台：等用户离开，或改用后台量（去掉 -CuePadForeground YES）\n".utf8))
        exit(2)
    }

    static func borrow(_ window: NSWindow) -> Bool {
        guard DebugScene.args.driveOpts.foreground else { return false }
        if lender == nil, let front = NSWorkspace.shared.frontmostApplication, front != .current { lender = front }
        holding = true
        _ = watching
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        askFront(!NSApp.isActive)
        return true
    }

    static func require(_ window: NSWindow, for what: String) {
        guard !borrow(window) else { return }
        FileHandle.standardError.write(Data("\(what) 要占前台：加 -CuePadForeground YES（apple/scripts/AGENTS.md「占前台」）\n".utf8))
        exit(2)
    }

    static func movePointer(to point: CGPoint) {
        if pointer == nil { pointer = CGEvent(source: nil)?.location }
        CGWarpMouseCursorPosition(point)
    }

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
            } catch {
                DebugScene.abandon("要前台的请求文件删不掉", error)
            }
        }
    }
}
#endif
