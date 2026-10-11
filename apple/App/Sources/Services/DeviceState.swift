import Foundation
import Synchronization
#if os(macOS)
import AppKit
import IOKit.ps
#else
import Network
import UIKit
#endif

/// 记录到达那一刻这台设备的状态，写进同步到达日志（`CueSync.ArrivalLog`），分析时据此分场景：
/// Mac 是 `app=active|inactive|hidden lock=yes|no screen=on|off wake=<唤醒后秒数>|none power=ac|battery`，
/// 手机是 `app=active|inactive|background net=wifi|cellular|wired|other|none lpm=yes|no`。
/// 状态由系统通知镜像进一把锁里，任何线程读都不碰界面对象。
nonisolated final class DeviceState: Sendable {
    static let current = DeviceState()

    #if os(macOS)
    private struct Flags {
        var app = "active"
        var locked = false
        var screenOn = true
        var wokeAt: Date?
    }
    #else
    private struct Flags {
        var app = "active"
        var net = "none"
    }
    #endif

    private let flags = Mutex(Flags())
    private let started = Atomic(false)

    /// 幂等；主线程调用（读一次初始的前后台状态并开始监听）。
    @MainActor
    func start() {
        guard !started.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).original else { return }
        observe()
    }

    func snapshot() -> String {
        #if os(macOS)
        let state = flags.withLock { $0 }
        let wake = state.wokeAt.map { Date.now.timeIntervalSince($0) }.flatMap { $0 < Self.wakeWindow ? "\(Int($0))s" : nil } ?? "none"
        return "app=\(state.app) lock=\(state.locked ? "yes" : "no") screen=\(state.screenOn ? "on" : "off") wake=\(wake) power=\(Self.power)"
        #else
        let state = flags.withLock { $0 }
        return "app=\(state.app) net=\(state.net) lpm=\(ProcessInfo.processInfo.isLowPowerModeEnabled ? "yes" : "no")"
        #endif
    }

    #if os(macOS)
    /// 唤醒后这么久内算"刚唤醒"。
    private static let wakeWindow: TimeInterval = 120

    private static var power: String {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        return IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String? == kIOPSACPowerValue ? "ac" : "battery"
    }

    @MainActor
    private func observe() {
        flags.withLock { $0.app = NSApplication.shared.isActive ? "active" : "inactive" }
        let center = NotificationCenter.default
        func set(_ name: Notification.Name, _ app: String) {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.flags.withLock { $0.app = app } }
        }
        set(NSApplication.didBecomeActiveNotification, "active")
        set(NSApplication.didResignActiveNotification, "inactive")
        set(NSApplication.didHideNotification, "hidden")
        set(NSApplication.didUnhideNotification, "inactive")
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.flags.withLock { $0.wokeAt = .now }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.flags.withLock { $0.screenOn = false }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.flags.withLock { $0.screenOn = true }
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil) { [weak self] _ in
            self?.flags.withLock { $0.locked = true }
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: nil) { [weak self] _ in
            self?.flags.withLock { $0.locked = false }
        }
    }
    #else
    @MainActor
    private func observe() {
        flags.withLock { $0.app = Self.name(UIApplication.shared.applicationState) }
        let center = NotificationCenter.default
        func set(_ name: Notification.Name, _ app: String) {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.flags.withLock { $0.app = app } }
        }
        set(UIApplication.didBecomeActiveNotification, "active")
        set(UIApplication.willResignActiveNotification, "inactive")
        set(UIApplication.didEnterBackgroundNotification, "background")
        set(UIApplication.willEnterForegroundNotification, "inactive")
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let net =
                path.status != .satisfied ? "none"
                : path.usesInterfaceType(.wifi) ? "wifi" : path.usesInterfaceType(.cellular) ? "cellular"
                : path.usesInterfaceType(.wiredEthernet) ? "wired" : "other"
            self?.flags.withLock { $0.net = net }
        }
        monitor.start(queue: DispatchQueue(label: "com.sugeh.cuepad.device-state"))
    }

    private static func name(_ state: UIApplication.State) -> String {
        switch state {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "inactive"
        }
    }
    #endif
}
