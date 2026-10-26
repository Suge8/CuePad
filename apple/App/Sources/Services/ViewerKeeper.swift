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

/// 这台设备此刻开着哪一页、他什么时候来到这台（`Viewer`，规则在它的头注释）只由这里写，只在变了时写一次，写成立即上传；没有心跳。
/// 来到这台（`arrive`）：手机点开与每次回到前台（`AppServices.followArrivals` 报来）；Mac 读到他最近来到的是别的设备（`CueStore.leftFor`）就算人不在跟前（`Away.elsewhere`），回到这台的第一下键盘鼠标才回来、记下来到。
/// 开着的那一页由界面报来：会话页（`show`）Mac 是人看得到主窗口时内容区的会话页，手机是场景前台活跃时导航最上面的会话页
/// （都是 `Workspace.shownSession`；iPad 开几个窗口各报各的，取最近开的那个）；Cue 页（`showCue`）两端都由 `CueViewing` 报（iPad 上它可以在面板里、
/// 不在导航最上面）。Mac 上人不在跟前（系统将睡眠、屏幕睡了、锁屏、退出、他去了别的设备，或 `SessionPresence.window` 没动过键盘鼠标）时一概算没开着，
/// 回来再按界面报的算；退出时写完、传完才放行，手机进后台时写完、传完。将睡眠不拖住系统：Mac 的这条只在那台 Mac 在线时算数（`Viewer`），
/// `MacPresenceKeeper` 在将睡眠时同步写下离线，它在各端就作废了。
/// 写的那一刻在 Store 的隔离域里读开着哪一页：几路写入谁先谁后，库里留下的都是最后的那个状态。
nonisolated final class ViewerKeeper: Sendable {
    /// 开着的会话页：会话记录 id；`sessionID` 是 Pi 的会话 id，只有记录 id 的入口（点通知进来）不带，写时从记录里取。
    struct Page: Equatable, Sendable {
        let id: UUID
        let sessionID: String?
    }

    /// Mac 上人不在跟前的原因：几样可能同时成立（锁着屏时屏幕亮了还是锁着），都过去了才算回来。`elsewhere`：他最近来到的是别的设备。
    enum Away: Hashable, Sendable {
        case asleep, screenOff, locked, idle, elsewhere, quitting
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
    /// 人在不在跟前变了（Mac：`Away` 有没有），界面据此算在不在看（`AppServices.seesMainWindow`）。
    private let aways: AsyncStream<Bool>
    private let awayChanged: AsyncStream<Bool>.Continuation
    private static let log = Logger(subsystem: AppIdentity.id, category: "services")

    init(store: CueStore, sync: (any SyncControlling)?, device: String) {
        self.store = store
        self.sync = sync
        self.device = device
        (changes, changed) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (aways, awayChanged) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
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

    /// 写下界面报来的变化，直到任务取消；Mac 另跟系统的睡眠、屏幕与锁屏，与他去没去别的设备。
    func keep(notifications center: NotificationCenter = .default) async throws {
        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { for await _ in self.changes { try await self.publish() } }
            #if os(macOS)
            let distributed = DistributedNotificationCenter.default()
            let events: [(NotificationCenter, Notification.Name, Away, Bool)] = [
                (center, NSWorkspace.willSleepNotification, .asleep, true),
                (center, NSWorkspace.didWakeNotification, .asleep, false),
                (center, NSWorkspace.screensDidSleepNotification, .screenOff, true),
                (center, NSWorkspace.screensDidWakeNotification, .screenOff, false),
                (distributed, Notification.Name("com.apple.screenIsLocked"), .locked, true),
                (distributed, Notification.Name("com.apple.screenIsUnlocked"), .locked, false),
            ]
            for (source, name, reason, gone) in events {
                group.addTask { for await _ in source.notifications(named: name) { self.mark(reason, gone) } }
            }
            group.addTask { await self.followIdle() }
            group.addTask { try await self.followElsewhere() }
            #endif
        }
    }

    /// 当场写下此刻开着哪个并传完（手机进后台时：挂起后就传不出去了）。
    func settle() async {
        do { try await publish() } catch { Self.log.error("没能写下这台设备开着的会话：\(error.localizedDescription, privacy: .public)") }
    }

    private func update(_ edit: (inout State) -> Void) {
        let (moved, away) = state.withLock { state in
            let before = (state.viewing, state.away.isEmpty)
            edit(&state)
            return (state.viewing != before.0, state.away.isEmpty != before.1 ? !state.away.isEmpty : nil)
        }
        if moved { changed.yield() }
        if let away { awayChanged.yield(away) }
    }

    private func mark(_ reason: Away, _ gone: Bool) {
        update { if gone { $0.away.insert(reason) } else { $0.away.remove(reason) } }
    }

    private func publish() async throws {
        guard let id = try await record(in: store) else { return }
        await sync?.upload(id)
    }

    /// 他来到了这台（`CueStore.arrive`），当场传出去：别的 Mac 据此让位。
    func arrive() async {
        do {
            let id = try await store.arrive(device: device)
            await sync?.upload(id)
        } catch {
            Self.log.error("没能写下他来到这台：\(error.localizedDescription, privacy: .public)")
        }
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
    /// 人走开了：键盘鼠标 `SessionPresence.window` 没动（与"在场"同一个口径）就算不在跟前，回来的第一下输入就回来。
    /// 只认真人的输入（`hidSystemState`，别的程序合成的事件不算）。没到点就睡到会到点的那一刻再查一次，走开期间等系统的输入事件，不轮询。
    private func followIdle() async {
        let limit = SessionPresence.window, anyInput = CGEventType(rawValue: ~0)!
        while !Task.isCancelled {
            let idle = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
            guard idle >= limit else {
                do { try await Task.sleep(for: .seconds(limit - idle)) } catch { return }
                continue
            }
            mark(.idle, true)
            await Self.nextInput()
            mark(.idle, false)
        }
    }

    /// 他去了别的设备（`CueStore.leftFor`）：算人不在跟前，回到这台的第一下键盘鼠标先记下来到这台、再回来。
    /// 来到这台写进库后判断随之变回，所以订阅里的下一个值就是"没去别处"。
    private func followElsewhere() async throws {
        for try await left in store.observe({ [device] in try $0.leftFor(device: device) }) where left {
            mark(.elsewhere, true)
            await Self.nextInput()
            guard !Task.isCancelled else { return }
            await arrive()
            mark(.elsewhere, false)
        }
    }

    /// 下一下键盘鼠标输入（在别的 App 里与在 CuePad 里的都算）；任务取消时也返回。
    @MainActor private static func nextInput() async {
        let (inputs, input) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown, .flagsChanged]
        let monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: mask) { _ in input.yield() },
            NSEvent.addLocalMonitorForEvents(matching: mask) { event in
                input.yield()
                return event
            },
        ].compactMap(\.self)
        defer { monitors.forEach(NSEvent.removeMonitor) }
        for await _ in inputs { return }
    }

    func signOff() async {
        state.withLock { _ = $0.away.insert(.quitting) }
        await settle()
    }

    /// 跟着主窗口，直到任务取消：把这台 Mac 上的人看不看得到主窗口交给界面（`AppServices.seesMainWindow` 的两半：窗口露没露在屏上、
    /// 人在不在跟前），再报开着的会话页（`Workspace.shownSession`，页一换或看得到与否一变就重算）。
    @MainActor func follow(_ workspace: Workspace) async {
        let services = workspace.services, window = UUID()
        let away = Task { for await away in aways { services.away = away } }
        let exposure = Task { await Self.followExposure(services) }
        defer {
            away.cancel()
            exposure.cancel()
        }
        for await page in Observations({ services.seesMainWindow ? workspace.shownSession : nil }) { show(page, in: window) }
    }

    @MainActor private static func followExposure(_ services: AppServices) async {
        guard let shell = services.windowShell else { return }
        services.mainWindowExposed = shell.occlusionState.contains(.visible)
        for await _ in NotificationCenter.default.notifications(named: NSWindow.didChangeOcclusionStateNotification, object: shell) {
            services.mainWindowExposed = shell.occlusionState.contains(.visible)
        }
    }

}
#else
/// 这个窗口在前台活跃时导航最上面的会话页，报给 `ViewerKeeper`；窗口关掉时收回。
struct SessionViewing: ViewModifier {
    let keeper: ViewerKeeper?
    let workspace: Workspace
    @Environment(\.scenePhase) private var phase
    @State private var window = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: phase == .active ? workspace.shownSession : nil, initial: true) { _, page in
                keeper?.show(page, in: window)
            }
            .onDisappear { keeper?.show(nil, in: window) }
    }
}
#endif
