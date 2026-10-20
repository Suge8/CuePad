#if os(macOS)
import AppKit
#else
import SwiftUI
import UIKit
#endif
import CueStore
import Foundation
import os
import Synchronization

/// 这台设备此刻开着哪一页（`Viewer`，规则在它的头注释）只由这里写，只在开着的页变了时写一次，写成立即上传；没有心跳。
/// 开着的那一页由界面报来：会话页（`show`）Mac 是主窗口在前台时内容区的会话页（`Workspace.openSession`），手机是场景前台活跃时导航最上面的会话页
/// （`Navigation.shownSession`；iPad 开几个窗口各报各的，取最近开的那个）；Cue 页（`showCue`）两端都由 `CueViewing` 报（iPad 上它可以在面板里、
/// 不在导航最上面）。Mac 上人不在跟前（系统将睡眠、屏幕睡了、锁屏、退出）时一概算没开着，
/// 回来再按界面报的算；将睡眠与退出同步写完、传完才放行（做法同 `MacPresenceKeeper`），手机进后台时写完、传完。
/// 写的那一刻在 Store 的隔离域里读开着哪一页：几路写入谁先谁后，库里留下的都是最后的那个状态。
nonisolated final class ViewerKeeper: Sendable {
    /// 开着的会话页：会话记录 id；`sessionID` 是 Pi 的会话 id，只有记录 id 的入口（点通知进来）不带，写时从记录里取。
    struct Page: Equatable, Sendable {
        let id: UUID
        let sessionID: String?
    }

    /// Mac 上人不在跟前的原因：几样可能同时成立（锁着屏时屏幕亮了还是锁着），都过去了才算回来。
    enum Away: Hashable, Sendable {
        case asleep, screenOff, locked, quitting
    }

    private struct State {
        /// 各窗口此刻开着的会话页，最近开的在后。
        var shown: [(window: UUID, page: Page)] = []
        var cue = false
        var away: Set<Away> = []
        var viewing: Viewing { away.isEmpty ? Viewing(session: shown.last?.page, cue: cue) : Viewing(session: nil, cue: false) }
    }

    private struct Viewing: Equatable {
        var session: Page?
        var cue: Bool
    }

    private let store: CueStore
    private let sync: (any SyncControlling)?
    private let device: String
    private let state = Mutex(State())
    private let changes: AsyncStream<Void>
    private let changed: AsyncStream<Void>.Continuation
    private static let log = Logger(subsystem: AppServices.bundleID, category: "services")

    init(store: CueStore, sync: (any SyncControlling)?, device: String) {
        self.store = store
        self.sync = sync
        self.device = device
        (changes, changed) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// 一个窗口开着的会话页（nil：没开着，或窗口不在前台）。开着哪个变了就由 `keep` 当场写。
    func show(_ page: Page?, in window: UUID) {
        update { state in
            state.shown.removeAll { $0.window == window }
            if let page { state.shown.append((window, page)) }
        }
    }

    /// 这台设备开没开着 Cue 页（`CueViewing` 数的在看的有没有）。
    func showCue(_ shown: Bool) {
        update { $0.cue = shown }
    }

    /// 写下界面报来的变化，直到任务取消；Mac 另跟系统的睡眠、屏幕与锁屏。
    func keep(notifications center: NotificationCenter = .default) async throws {
        #if os(macOS)
        let sleeping = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [self] _ in goingToSleep() }
        defer { center.removeObserver(sleeping) }
        #endif
        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { for await _ in self.changes { try await self.publish() } }
            #if os(macOS)
            let distributed = DistributedNotificationCenter.default()
            let events: [(NotificationCenter, Notification.Name, Away, Bool)] = [
                (center, NSWorkspace.didWakeNotification, .asleep, false),
                (center, NSWorkspace.screensDidSleepNotification, .screenOff, true),
                (center, NSWorkspace.screensDidWakeNotification, .screenOff, false),
                (distributed, Notification.Name("com.apple.screenIsLocked"), .locked, true),
                (distributed, Notification.Name("com.apple.screenIsUnlocked"), .locked, false),
            ]
            for (source, name, reason, gone) in events {
                group.addTask { for await _ in source.notifications(named: name) { self.mark(reason, gone) } }
            }
            #endif
        }
    }

    /// 当场写下此刻开着哪个并传完（手机进后台时：挂起后就传不出去了）。
    func settle() async {
        do { try await publish() } catch { Self.log.error("没能写下这台设备开着的会话：\(error.localizedDescription, privacy: .public)") }
    }

    private func update(_ edit: (inout State) -> Void) {
        let moved = state.withLock { state in
            let before = state.viewing
            edit(&state)
            return state.viewing != before
        }
        if moved { changed.yield() }
    }

    private func mark(_ reason: Away, _ gone: Bool) {
        update { if gone { $0.away.insert(reason) } else { $0.away.remove(reason) } }
    }

    private func publish() async throws {
        guard let id = try await record(in: store) else { return }
        await sync?.upload(id)
    }

    private func record(in store: isolated CueStore) throws -> UUID? {
        let viewing = state.withLock { $0.viewing }
        let sessionID = try viewing.session.flatMap { page in
            try page.sessionID ?? store.piSessionPage(PiSessionQuery(id: page.id)).items.first?.state.sessionID
        }
        return try store.recordViewing(device: device, sessionID: sessionID, cue: viewing.cue)
    }
}

#if os(macOS)
nonisolated extension ViewerKeeper {
    /// 退出时：写成离开并上传。
    func signOff() async {
        state.withLock { _ = $0.away.insert(.quitting) }
        await settle()
    }

    /// 在系统发将睡眠通知的线程上同步等离开这一条写完、传完（理由同 `MacPresenceKeeper.goingToSleep`）。
    private func goingToSleep() {
        state.withLock { _ = $0.away.insert(.asleep) }
        let done = DispatchSemaphore(value: 0)
        Task.detached { [self] in
            await settle()
            done.signal()
        }
        if done.wait(timeout: .now() + MacPresenceKeeper.sleepUploadLimit) == .timedOut {
            Self.log.notice("将睡眠：这台 Mac 离开那一页的记录 \(Int(MacPresenceKeeper.sleepUploadLimit)) 秒内没传完")
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
/// 这个窗口在前台活跃时导航最上面的会话页，报给 `ViewerKeeper`；窗口关掉时收回。
struct SessionViewing: ViewModifier {
    let keeper: ViewerKeeper?
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
