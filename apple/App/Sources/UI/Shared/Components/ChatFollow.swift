import SwiftUI

nonisolated struct ChatFollow: Equatable {
    private(set) var atNewest = true
    private(set) var showsJump = false
    private(set) var nearOldest = false
    private(set) var prepending = false
    private(set) var toNewest: ToNewest?
    private(set) var target: Target?
    private(set) var seeking: Target?
    private(set) var owesLanding = false
    var scrolling = false {
        didSet {
            if scrolling {
                jumping = false
                opened = []
                target = nil
                owesLanding = false
            }
            if scrolling, !withinSlack {
                atNewest = false
                revealed = false
            }
        }
    }
    private var jumping = false
    private var opened: Set<UUID> = []
    private var growingUp: Set<UUID> = []
    private var withinSlack = true
    private var revealed = false
    private(set) var deferred = false
    private var unheld = false
    static let slack: CGFloat = 24

    var wantsEarlier: Bool { nearOldest && !prepending }

    var showsHeader: Bool { atNewest || revealed }

    struct Target: Equatable {
        let id: UUID
        var landing = Landing.flash
        let request = UUID()

        var anchor: UnitPoint { landing == .read ? .top : .center }
    }

    enum Landing { case flash, read }

    struct ToNewest: Equatable {
        let sent: Bool
        let request = UUID()
    }

    mutating func scrolled(atNewest near: Bool, beyondScreen: Bool, nearOldest: Bool, byUser: Bool) {
        showsJump = beyondScreen
        self.nearOldest = nearOldest
        withinSlack = near
        if !near { jumping = false }
        if near, !jumping, opened.isEmpty {
            atNewest = true
            revealed = false
        } else if byUser {
            atNewest = false
            revealed = false
        }
    }

    /// 钮在底边的折叠（`RisingFold`）开合的那一段：它底下的都不动、内容朝上长，滚动区不把这段高当成末尾新长出来的。
    mutating func grow(_ key: UUID, _ growing: Bool) {
        if growing { growingUp.insert(key) } else { growingUp.remove(key) }
    }

    var growsUp: Bool { !growingUp.isEmpty }

    mutating func stay(_ key: UUID, _ open: Bool) {
        guard open else {
            opened.remove(key)
            return
        }
        if atNewest {
            atNewest = false
            revealed = true
        }
        opened.insert(key)
    }

    func pinned(holding: Bool) -> Bool { atNewest && !scrolling && (!holding || unheld) && !deferred }

    mutating func deferGrowth(holding: Bool) -> Bool {
        guard holding, !unheld else { return false }
        deferred = true
        return true
    }

    mutating func holdingChanged(_ holding: Bool, sliding: Bool) -> Bool {
        unheld = false
        if holding, sliding { deferred = true }
        guard !holding, deferred else { return false }
        deferred = false
        return true
    }

    mutating func reveal() {
        if !atNewest { revealed = true }
    }

    mutating func jumpToNewest() { returnToNewest(sent: false) }

    mutating func sent() { returnToNewest(sent: true) }

    private mutating func returnToNewest(sent: Bool) {
        owesLanding = false
        atNewest = true
        revealed = false
        jumping = false
        opened = []
        target = nil
        deferred = false
        unheld = true
        toNewest = ToNewest(sent: sent)
    }

    mutating func willPrepend() { prepending = true }

    mutating func prepended(nearOldest: Bool) {
        prepending = false
        self.nearOldest = nearOldest
    }

    mutating func seek(_ id: UUID, landing: Landing = .flash) {
        owesLanding = false
        seeking = Target(id: id, landing: landing)
    }

    mutating func oweLanding() { owesLanding = true }

    mutating func land(on first: UUID?) {
        guard owesLanding else { return }
        owesLanding = false
        if let first { seeking = Target(id: first, landing: .read) }
    }

    mutating func jump(to target: Target) {
        atNewest = false
        revealed = false
        jumping = true
        self.target = target
    }
}

/// 跳到对话里的某一条（`chatJump`）。按所在的对话区比较：同一个对话区每次更新换出的闭包做的是同一件事（改的是同一个 `ChatFollow`），
/// 读它的行（每轮的经过）不因换了一个闭包跟着重算；闭包本身不能比较，直接放进环境时每次更新都让读它的视图失效。
struct ChatJump: Equatable {
    let column: UUID
    let seek: (UUID) -> Void

    func callAsFunction(_ id: UUID) { seek(id) }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.column == b.column }
}

struct ChatStay: Equatable {
    let column: UUID
    let stay: (UUID, Bool) -> Void
    let grow: (UUID, Bool) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool { a.column == b.column }
}

nonisolated enum ChatLayout {
    static let edge: CGFloat = 16

    static func margin(_ width: CGFloat, readingWidth: CGFloat, inset: CGFloat) -> CGFloat { max(inset, (width - readingWidth) / 2 + inset) }
}

extension EnvironmentValues {
    @Entry var chatHighlight: UUID?
    @Entry var chatTarget: UUID?
    @Entry var chatJump: ChatJump?
    @Entry var chatStay: ChatStay?
    @Entry var chatBottomInset: CGFloat = 0
    @Entry var chatLift: ContentLift?
    @Entry var chatHeight: CGFloat = .infinity
    @Entry var chatMargin: CGFloat = 0
}

struct JumpToNewest: View {
    let unseen: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            FloatingGlyph(icon: .toLatest)
                .overlay(alignment: .topTrailing) {
                    if unseen {
                        StatusDot(color: palette.ink, rim: palette.desk)
                            .offset(x: -5, y: 5)
                            .transition(Motion.pop(reduceMotion: reduceMotion))
                    }
                }
        }
        .buttonStyle(PressStyle(.button))
        .accessibilityLabel(unseen ? "回到最新，有新内容" : "回到最新")
    }
}
