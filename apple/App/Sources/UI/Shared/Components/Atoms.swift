import CueStore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension EnvironmentValues {
    /// Mac 的内容区把去过的页都挂着（`Workspace.mountedPages`），不在前台的页暂停订阅、不读实时状态；其余地方没有"挂着不看"的页，默认 true。
    @Entry var pageActive = true
    /// 不在前台、但要先读一份数据的页（空闲时先挂上的 `Workspace.premount`、收着的 ⌘K）：只读第一份，不跟着变。
    @Entry var pagePrefetch = false
}

extension View {
    /// 读到的和上一次一样就不写：在 Store 一侧比一次，重新订阅后手里已有的值当作"上一次"，没变的数据不送到主线程、界面也不重算。
    /// 在前台、手里还没有值时当场读（`CueStore.snapshot`，`onAppear` 在第一帧之前做完）再从它接着订阅：本机库里的东西第一帧就排好，页面没有"还没读到"这一态。读失败时留给订阅报告，不报两次。
    /// `immediately: false`：长列表里每行各自的小读（附件到没到本机，要看文件在不在），行在滚动中一个个出现，不在主线程上读，没读到时按到了画。
    func observing<T: Sendable & Equatable>(
        _ store: CueStore, id: some Equatable = 0, into value: Binding<T?>, immediately: Bool = true,
        onError: @escaping (any Error) -> Void = { _ in },
        _ read: @escaping @Sendable (isolated CueStore) throws -> T
    ) -> some View {
        modifier(Observing(store: store, id: id, value: value, immediately: immediately, onError: onError, read: read))
    }
}

extension View {
    /// 系统在它自己的线程上发这个通知：按主线程上的任务等，`action` 改的界面状态不跨线程。
    func onDayChange(_ action: @escaping () -> Void) -> some View {
        task { for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged) { action() } }  // 晚订：视图出现前换的日子，出现时画的就是新的一天
    }
}

private struct Observing<T: Sendable & Equatable, ID: Equatable>: ViewModifier {
    let store: CueStore
    let id: ID
    @Binding var value: T?
    let immediately: Bool
    let onError: (any Error) -> Void
    let read: @Sendable (isolated CueStore) throws -> T
    @Environment(\.pageActive) private var active
    @Environment(\.pagePrefetch) private var prefetch
    @State private var start: Snapshot<T>?

    private struct Run: Equatable {
        let id: ID
        let active: Bool
    }

    func body(content: Content) -> some View {
        content
            .onAppear(perform: readNow)
            .onChange(of: Run(id: id, active: active), readNow)
            .task(id: Run(id: id, active: active)) {
                guard active || prefetch && value == nil else { return }
                let updates = start.map { store.observe(from: $0, read) } ?? store.observe(after: value, read)
                start = nil
                await follow(updates)
            }
    }

    private func readNow() {
        guard immediately, active, value == nil, let snapshot = try? store.snapshot(read) else { return }
        start = snapshot
        // 当场读到的是这一页本来的样子，不是变化：页面上挂在这些值上的动画（`animation(_:value:)`）不播，
        // 不然从"还没读到"到读到的那一截连同同一次更新里的版面变化（冷启动时内容区从占位尺寸到真实尺寸）一帧帧排过去
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { value = snapshot.value }
        DebugHooks.observed(snapshot.value)
    }

    private func follow(_ updates: AsyncThrowingStream<T, any Error>) async {
        do {
            for try await next in updates {
                value = next
                DebugHooks.observed(next)
                if !active { return }
            }
        } catch is CancellationError {
        } catch {
            onError(error)
        }
    }
}

/// 读屏不念（行要读的话由行自己的标签给）。
struct Dot: View {
    var body: some View { Text("·").readerHidden(true) }
}

struct ProjectGlyph: View {
    let project: Project?
    var size: CGFloat = 13
    @Environment(\.palette) private var palette

    var body: some View {
        Image(Self.icon(project))
            .font(.system(size: size, weight: .medium))
            // 项目还没同步到时是墨色，不借系统灰或系统强调色（侧栏列表会把 Label 的图标染成强调蓝）
            .foregroundStyle(project.map { palette.project($0.color) } ?? palette.ink2)
            .frame(width: size + Self.margin)
            .readerHidden(true)
    }

    static let margin: CGFloat = 6

    static func icon(_ project: Project?) -> Icon { .project(ProjectIcon(stored: project?.icon)) }
}

/// 库里存的值不迁移：表外的名字认不出，是文件夹（含没存图标的）。
nonisolated enum ProjectIcon: String, CaseIterable, Sendable {
    // rawValue 就是库里已存的名字（早先表单存的系统符号名，更早版本存的 lucide 名 rocket）：已有项目直接认得，不用映射
    case folder, sparkles, chat = "bubble.left.and.bubble.right", terminal, globe, hammer, book, target
    case briefcase, cart, megaphone, paintbrush, lightbulb, flag, cube, leaf
    case layers, camera, house, heart, star, music = "music.note", rocket, bolt

    init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .folder
    }

    var name: LocalizedStringResource {
        switch self {
        case .folder: "文件夹"
        case .sparkles: "闪光"
        case .chat: "对话"
        case .terminal: "终端"
        case .globe: "地球"
        case .hammer: "锤子"
        case .book: "书"
        case .target: "靶心"
        case .briefcase: "公文包"
        case .cart: "购物车"
        case .megaphone: "喇叭"
        case .paintbrush: "画笔"
        case .lightbulb: "灯泡"
        case .flag: "旗帜"
        case .cube: "方块"
        case .leaf: "叶子"
        case .layers: "层"
        case .camera: "相机"
        case .house: "家"
        case .heart: "心"
        case .star: "星"
        case .music: "音符"
        case .rocket: "火箭"
        case .bolt: "闪电"
        }
    }
}

extension LocalizedStringResource {
    /// 收界面字的参数拿到的是已经算好或用户写的字（项目名、会话标题、Agent 说的）：原样显示，不查目录。
    static func verbatim(_ text: String) -> Self { "\(text)" }
}

extension View {
    /// 分开时 Mac 的菜单按钮按子视图拆成几颗，菜单项只挂在第一颗下，读屏落在别的那颗上打开的是空壳。标签只有一个图标时不用它，给菜单本身 `accessibilityLabel` 就够。
    func menuLabel(_ spoken: LocalizedStringResource) -> some View { accessibilityElement(children: .ignore).accessibilityLabel(spoken) }
}

/// 全 App 唯一的"什么时候"写法。会话的计时会随时间刷新（`SessionElapsed`）；灵感卡、回收站这些不加定时器，写的是打开时的值。
nonisolated enum DateLabel {
    static func short(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let elapsed = Int(now.timeIntervalSince(date))
        if elapsed < 60 { return String(localized: "刚刚") }
        if elapsed < 3600 { return relative(DateComponents(minute: -elapsed / 60), style: .abbreviated) }
        if elapsed < 86_400 { return relative(DateComponents(hour: -elapsed / 3600), style: .abbreviated) }
        return day(date, now: now, calendar: calendar)
    }

    static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return relative(DateComponents(day: -1), style: .full)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(monthDay) }
        return date.formatted(.dateTime.year().month(.defaultDigits).day())
    }

    static let monthDay = Date.FormatStyle.dateTime.month(.defaultDigits).day()

    private static func relative(_ offset: DateComponents, style: RelativeDateTimeFormatter.UnitsStyle) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = style
        formatter.dateTimeStyle = .named
        formatter.formattingContext = .beginningOfSentence
        return formatter.localizedString(from: offset)
    }
}

struct SectionHeader: View {
    enum Level { case page, group }

    let title: Dotted
    var level = Level.page
    var count: Int?
    var icon: Icon?
    @Environment(\.palette) private var palette

    init(_ title: Dotted, level: Level = .page, count: Int? = nil, icon: Icon? = nil) {
        self.title = title
        self.level = level
        self.count = count
        self.icon = icon
    }

    init(_ title: LocalizedStringResource, level: Level = .page, count: Int? = nil, icon: Icon? = nil) {
        self.init(Dotted(String(localized: title)), level: level, count: count, icon: icon)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.glyph) {
            if let icon { Image(icon).readerHidden(true) }
            Text(title)
            if let count { Text("\(count)").font(countFont).monospacedDigit().foregroundStyle(palette.ink3).counting(count) }
        }
        .font(titleFont)
        .foregroundStyle(level == .page ? palette.ink : palette.ink3)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var titleFont: Font {
        level == .page ? Typography.sectionTitle : Typography.label
    }

    private var countFont: Font {
        level == .page ? Typography.sectionCount : Typography.label
    }
}
