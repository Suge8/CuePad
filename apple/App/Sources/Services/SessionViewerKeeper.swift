#if os(macOS)
import AppKit
import CoreGraphics
#else
import SwiftUI
import UIKit
#endif
import CueStore
import Foundation
import os
import Synchronization

/// 这台设备此刻开着哪个会话（`SessionViewer`，规则在它的头注释）只由这里写，每次写成立即上传。
/// 开着的那一页由界面报来（`show`）：Mac 是主窗口在前台时内容区的会话页（`Workspace.openSession`），手机是场景前台活跃时导航最上面的会话页
/// （`Navigation.shownSession`；iPad 开几个窗口各报各的，取最近开的那个）。一变当场写；开着时每 `SessionViewer.renewal` 续一次，
/// Mac 续期按系统多久没有键鼠推最近一次有人在用的时刻，过了 `SessionViewer.lifetime` 就写成离开。
/// Mac 将睡眠与退出、手机进后台时写成离开并传完（睡眠同步等，做法同 `MacPresenceKeeper`）。
/// 写的那一刻在 Store 的隔离域里读开着哪一页：界面报的、续期的与离开的写入谁先谁后，库里留下的都是最后的那个状态。
nonisolated final class SessionViewerKeeper: Sendable {
    /// 开着的会话页：会话记录 id；`sessionID` 是 Pi 的会话 id，只有记录 id 的入口（点通知进来）不带，写时从记录里取。
    struct Page: Equatable, Sendable {
        let id: UUID
        let sessionID: String?
    }

    private struct State {
        /// 各窗口此刻开着的，最近开的在后。
        var shown: [(window: UUID, page: Page)] = []
        /// Mac 醒着且没在退出。
        var awake = true
        var viewing: Page? { awake ? shown.last?.page : nil }
    }

    private let store: CueStore
    private let sync: (any SyncControlling)?
    private let device: String
    /// 系统多久没有键鼠（秒）；手机按屏幕亮着、在前台就算在用，为 0。
    private let idle: @Sendable () -> TimeInterval
    private let state = Mutex(State())
    private let changes: AsyncStream<Void>
    private let changed: AsyncStream<Void>.Continuation
    private static let log = Logger(subsystem: AppServices.bundleID, category: "services")

    init(store: CueStore, sync: (any SyncControlling)?, device: String, idle: @escaping @Sendable () -> TimeInterval) {
        self.store = store
        self.sync = sync
        self.device = device
        self.idle = idle
        (changes, changed) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// 一个窗口开着的会话页（nil：没开着，或窗口不在前台）。开着哪个变了就由 `keep` 当场写。
    func show(_ page: Page?, in window: UUID) {
        let moved = state.withLock { state in
            let before = state.viewing
            state.shown.removeAll { $0.window == window }
            if let page { state.shown.append((window, page)) }
            return state.viewing != before
        }
        if moved { changed.yield() }
    }

    /// 写下界面报来的变化、到期续期，直到任务取消；Mac 另跟系统的将睡眠与醒来。
    func keep(notifications center: NotificationCenter = .default) async throws {
        #if os(macOS)
        let sleeping = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [self] _ in goingToSleep() }
        defer { center.removeObserver(sleeping) }
        #endif
        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { for await _ in self.changes { try await self.publish(renewing: false) } }
            group.addTask {
                while true {
                    try await self.store.timing.sleep(SessionViewer.renewal)
                    if self.state.withLock({ $0.viewing != nil }) { try await self.publish(renewing: true) }
                }
            }
            #if os(macOS)
            group.addTask {
                for await _ in center.notifications(named: NSWorkspace.didWakeNotification) {
                    self.state.withLock { $0.awake = true }
                    try await self.publish(renewing: false)
                }
            }
            #endif
        }
    }

    /// 当场写下此刻开着哪个并传完（手机进后台时：挂起后就传不出去了）。
    func settle() async {
        do { try await publish(renewing: false) } catch { Self.log.error("没能写下这台设备开着的会话：\(error.localizedDescription, privacy: .public)") }
    }

    private func publish(renewing: Bool) async throws {
        guard let id = try await record(in: store, renewing: renewing) else { return }
        await sync?.upload(id)
    }

    private func record(in store: isolated CueStore, renewing: Bool) throws -> UUID? {
        let now = store.timing.now()
        guard let page = state.withLock({ $0.viewing }) else { return try store.recordViewing(device: device, sessionID: nil, activeAt: now) }
        let activeAt = renewing ? now - idle() : now
        let sessionID =
            activeAt + SessionViewer.lifetime > now
            ? try page.sessionID ?? store.piSessionPage(PiSessionQuery(id: page.id)).items.first?.state.sessionID : nil
        return try store.recordViewing(device: device, sessionID: sessionID, activeAt: activeAt)
    }
}

#if os(macOS)
nonisolated extension SessionViewerKeeper {
    /// 系统多久没有键鼠：本机所有输入（`combinedSessionState`、任意事件），不要辅助功能权限。
    static let systemIdle: @Sendable () -> TimeInterval = {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// 退出时：写成离开并上传。
    func signOff() async {
        state.withLock { $0.awake = false }
        await settle()
    }

    /// 在系统发将睡眠通知的线程上同步等离开这一条写完、传完（理由同 `MacPresenceKeeper.goingToSleep`）。
    private func goingToSleep() {
        let done = DispatchSemaphore(value: 0)
        Task.detached { [self] in
            await signOff()
            done.signal()
        }
        if done.wait(timeout: .now() + MacPresenceKeeper.sleepUploadLimit) == .timedOut {
            Self.log.notice("将睡眠：这台 Mac 离开会话的记录 \(Int(MacPresenceKeeper.sleepUploadLimit)) 秒内没传完")
        }
    }

    /// 跟着主窗口报开着的会话页（`Workspace.openSession`），直到任务取消：页一换，或 App 与窗口的前台、可见一变就重算。
    @MainActor func follow(_ workspace: Workspace) async {
        let window = UUID(), center = NotificationCenter.default
        let (moves, moved) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let names = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification,
        ]
        let observers = names.map { center.addObserver(forName: $0, object: nil, queue: nil) { _ in moved.yield() } }
        let pages = Task { for await _ in Observations({ workspace.page }) { moved.yield() } }
        defer {
            pages.cancel()
            for observer in observers { center.removeObserver(observer) }
        }
        for await _ in moves { show(workspace.openSession, in: window) }
    }
}
#else
/// 这个窗口在前台活跃时导航最上面的会话页，报给 `SessionViewerKeeper`；窗口关掉时收回。
struct SessionViewing: ViewModifier {
    let keeper: SessionViewerKeeper?
    let navigation: Navigation
    @Environment(\.scenePhase) private var phase
    @State private var window = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: phase == .active ? navigation.shownSession : nil, initial: true) { _, page in
                keeper?.show(page, in: window)
            }
            .onDisappear { keeper?.show(nil, in: window) }
    }
}
#endif
