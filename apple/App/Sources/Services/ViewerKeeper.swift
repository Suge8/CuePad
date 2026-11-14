#if os(macOS)
import AppKit
#else
import SwiftUI
import UIKit
#endif
import CueStore
import Foundation
import os

/// 这台设备此刻开着哪些页、他什么时候来到这台（`Viewer`，规则在它的头注释）的唯一来源：界面读 `viewing`（拉取节奏、Cue 的提示与涟漪），
/// 库里那条只由这里写，只在变了时写一次，写成立即上传；没有心跳。没有设备标识（手机读不到 `identifierForVendor`）时只在本机算、不写。
/// 来到这台（`arrive`）：手机点开与每次回到前台（`AppServices.followArrivals` 报来）；Mac 读到他最近来到的是别的设备（`CueStore.leftFor`）就算人不在跟前（`Away.elsewhere`），回到这台的第一下键盘鼠标才回来、记下来到。
/// 开着的页由界面报来：会话页（`show`）是各窗口导航最上面的会话页（`Workspace.shownSessions`），Mac 由 `follow` 报、手机由场景前台活跃时的 `SessionViewing` 报，
/// iPad 开几个窗口各报各的，合并各窗口开着的页；Cue 页（`showCue`）两端都由 `CueViewing` 报（iPad 上它可以在面板里、不在导航最上面），每处各占一个标记，收回只收自己的。
/// Mac 上人不在跟前（系统将睡眠、屏幕睡了、锁屏、他去了别的设备、主窗口整个被盖住，或 `idleAfter` 没动过键盘鼠标）时一概算没开着，
/// 回来再按界面报的算；退出时写完、传完才放行，手机进后台时写完、传完。将睡眠不拖住系统：Mac 的这条只在那台 Mac 在线时算数（`Viewer`），
/// `MacPresenceKeeper` 在将睡眠时同步写下离线，它在各端就作废了。
/// 写的那一刻在 Store 的隔离域里读开着哪些页（`latest`）：几路写入谁先谁后，库里留下的都是最后的那个状态。
/// 退出（`signOff`）不经主线程：退出收尾时主线程可能正被占着；之后界面再报的都不写。
@MainActor @Observable
final class ViewerKeeper {
    /// 开着的会话页：会话记录 id；`sessionID` 是 Pi 的会话 id，只有记录 id 的入口（点通知进来）不带，写时从记录里取。
    nonisolated struct Page: Hashable, Sendable {
        let id: UUID
        let sessionID: String?
    }

    /// Mac 上人不在跟前的原因：几样可能同时成立（锁着屏时屏幕亮了还是锁着），都过去了才算回来。`elsewhere`：他最近来到的是别的设备；
    /// `covered`：主窗口整个被盖住或收起（有没有焦点都不算）。
    nonisolated enum Away: Hashable, Sendable {
        case asleep, screenOff, locked, idle, elsewhere, covered
    }

    nonisolated struct Viewing: Equatable, Sendable {
        var sessions: Set<Page> = []
        var cue = false
        var isEmpty: Bool { sessions.isEmpty && !cue }
    }

    private nonisolated struct Latest: Sendable {
        var viewing = Viewing()
        var quitting = false
        var written: Viewing { quitting ? Viewing() : viewing }
    }

    private var shown: [UUID: Set<Page>] = [:]
    private var cueShown: Set<UUID> = []
    private var away: Set<Away> = []

    /// 人在跟前、看得到主窗口（手机上总是）：界面判断"这一页在不在屏上"读它。
    var present: Bool { away.isEmpty }

    #if os(macOS)
    /// 主窗口被盖住，而且人也不在跟前：只是被盖住、人在用别的 App 时不算（`MainShellWindow.parkWhileUnseen`）。
    var unseen: Bool { away.contains(.covered) && !away.isDisjoint(with: [.asleep, .screenOff, .locked, .idle, .elsewhere]) }
    #endif

    /// 此刻算开着的页：人不在跟前时一概为空。
    var viewing: Viewing {
        present ? Viewing(sessions: Set(shown.values.flatMap(\.self)), cue: !cueShown.isEmpty) : Viewing()
    }

    @ObservationIgnored private let latest = OSAllocatedUnfairLock(initialState: Latest())
    @ObservationIgnored private let store: CueStore
    @ObservationIgnored private let sync: (any SyncControlling)?
    @ObservationIgnored private let device: String?
    @ObservationIgnored private let changes: AsyncStream<Void>
    @ObservationIgnored private let changed: AsyncStream<Void>.Continuation
    private static let log = Logger(subsystem: AppIdentity.id, category: "services")

    init(store: CueStore, sync: (any SyncControlling)?, device: String?) {
        self.store = store
        self.sync = sync
        self.device = device
        (changes, changed) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// 一个窗口开着的会话页（空数组：没开着，或窗口不在前台）。开着哪个变了就由 `keep` 当场写。
    func show(_ pages: [Page], in window: UUID) {
        shown[window] = pages.isEmpty ? nil : Set(pages)
        moved()
    }

    /// 一处 Cue 页在不在看（`token` 是那一处自己的标记）：任一处在看就算开着。
    func showCue(_ on: Bool, by token: UUID) {
        if on { cueShown.insert(token) } else { cueShown.remove(token) }
        moved()
    }

    func keep(notifications center: NotificationCenter = .default) async throws {
        #if os(macOS)
        let distributed = DistributedNotificationCenter.default()
        let sources: [(NotificationCenter, Notification.Name, Away, Bool)] = [
            (center, NSWorkspace.willSleepNotification, .asleep, true),
            (center, NSWorkspace.didWakeNotification, .asleep, false),
            (center, NSWorkspace.screensDidSleepNotification, .screenOff, true),
            (center, NSWorkspace.screensDidWakeNotification, .screenOff, false),
            (distributed, Notification.Name("com.apple.screenIsLocked"), .locked, true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), .locked, false),
        ]
        let events = sources.map { source, name, reason, gone in (source.notifications(named: name), reason, gone) }  // 在第一次写下之前订上
        #endif
        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { for await _ in self.changes { try await self.publish() } }
            #if os(macOS)
            for (marks, reason, gone) in events {
                group.addTask { for await _ in marks { await self.mark(reason, gone) } }
            }
            group.addTask { await self.followIdle() }
            group.addTask { try await self.followElsewhere() }
            #endif
        }
    }

    /// 当场写下此刻开着哪些页并传完（手机进后台时：挂起后就传不出去了）。
    func settle() async {
        do { try await publish() } catch { Self.log.error("没能写下这台设备开着的会话：\(error.localizedDescription, privacy: .public)") }
    }

    private func mark(_ reason: Away, _ gone: Bool) {
        if gone { away.insert(reason) } else { away.remove(reason) }
        moved()
    }

    private func moved() {
        let now = viewing
        if latest.withLock({ old in defer { old.viewing = now }; return old.viewing != now }) { changed.yield() }
    }

    @discardableResult
    private func publish() async throws -> Bool {
        guard let device, let id = try await Self.record(viewing: latest, device: device, in: store) else { return true }
        return await sync?.send(recordNames: [id.uuidString.lowercased()]) ?? true
    }

    /// 他来到了这台（`CueStore.arrive`），当场传出去：别的 Mac 据此让位。
    func arrive() async {
        guard let device else { return }
        do {
            try await store.arrive(device: device)
        } catch {
            Self.log.error("没能写下他来到这台：\(error.localizedDescription, privacy: .public)")
        }
    }

    private static func record(viewing latest: OSAllocatedUnfairLock<Latest>, device: String, in store: isolated CueStore) throws -> UUID? {
        let viewing = latest.withLock { $0.written }
        let sessionIDs = try viewing.sessions.compactMap { page in
            try page.sessionID ?? store.sessionPage(SessionQuery(id: page.id)).items.first?.state.sessionID
        }
        return try store.recordViewing(device: device, sessionIDs: Set(sessionIDs), cue: viewing.cue)
    }
}

#if os(macOS)
extension ViewerKeeper {
    /// 10 分钟：比读完一段回复、想一想再回的时间长，与常见即时通讯"多久没动静算离开"同一个量级。
    static let idleAfter: TimeInterval = 10 * 60

    /// 键盘鼠标 `idleAfter` 没动就算不在跟前，回来的第一下输入就回来。
    /// 只认真人的输入（`hidSystemState`，别的程序合成的事件不算）；走开期间等系统的输入事件，不轮询。
    private func followIdle() async {
        let limit = Self.idleAfter, anyInput = CGEventType(rawValue: ~0)!
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
        guard let device else { return }
        for try await left in store.observe({ [device] in try $0.leftFor(device: device) }) where left {
            mark(.elsewhere, true)
            await Self.nextInput()
            guard !Task.isCancelled else { return }
            await arrive()
            mark(.elsewhere, false)
        }
    }

    /// 下一下键盘鼠标输入（在别的 App 里与在 CuePad 里的都算）；任务取消时也返回。
    private static func nextInput() async {
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

    nonisolated func signOff() async throws -> Bool {
        latest.withLock { $0.quitting = true }
        guard let device else { return true }
        _ = try await Self.record(viewing: latest, device: device, in: store)
        return await sync?.send(recordNames: [Viewer.recordID(device: device).uuidString.lowercased()]) ?? true
    }

    /// 报这个窗口导航最上面的会话页，跟着主窗口露没露在屏上；脚本起的实例窗口排在最后，当它露着。
    func follow(_ workspace: Workspace) async {
        let window = UUID()
        let exposure = Task { await followExposure(workspace.services.windowShell) }
        defer {
            exposure.cancel()
            show([], in: window)
            mark(.covered, false)
        }
        for await pages in Observations({ workspace.shownSessions }) { show(pages, in: window) }
    }

    private func followExposure(_ shell: NSWindow?) async {
        guard let shell, !DebugHooks.scripted else { return }
        let changes = NotificationCenter.default.notifications(named: NSWindow.didChangeOcclusionStateNotification, object: shell)
        mark(.covered, !shell.occlusionState.contains(.visible))
        for await _ in changes {
            mark(.covered, !shell.occlusionState.contains(.visible))
        }
    }
}
#else
struct SessionViewing: ViewModifier {
    let keeper: ViewerKeeper
    let workspace: Workspace
    @Environment(\.scenePhase) private var phase
    @State private var window = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: phase == .active ? workspace.shownSessions : [], initial: true) { _, page in
                keeper.show(page, in: window)
            }
            .onDisappear { keeper.show([], in: window) }
    }
}
#endif
