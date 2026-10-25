import CueStore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: 订阅 Store

extension EnvironmentValues {
    /// 这一页此刻在前台。Mac 的内容区把去过的页都挂着（`Workspace.mountedPages`），不在前台的页暂停订阅（`observing`）、
    /// 不读实时状态；其余地方没有"挂着不看"的页，默认 true。
    @Entry var pageActive = true
    /// 不在前台、但要先读一份数据的页：空闲时先挂上、还没去过的（`Workspace.premount`），收着的常驻浮层（⌘K）。只读第一份，不跟着变。
    @Entry var pagePrefetch = false
}

extension View {
    /// 订阅 Store：`id` 变化时重新订阅；每次变更重读后写入 `value`。读失败交给 `onError`。页不在前台时暂停（见 `pageActive`），回到前台重新订阅；
    /// 空闲时先挂上、还没去过的页（`pagePrefetch`）照样先读一份，第一次点开时内容已经建好。
    /// 依赖哪些表由读取本身定（`CueStore.observe(_:)`），这里不另写；读到的和上一次一样就不写——在 Store 一侧比一次，
    /// 重新订阅后手里已有的值当作"上一次"，没变的数据不送到主线程、界面也不重算。
    /// 在前台、手里还没有值时（出现、换了 `id` 或回到前台的那一刻）当场读（`CueStore.snapshot`，`onAppear` 在第一帧之前做完）再从它接着订阅：
    /// 本机库里的东西第一帧就排好，页面没有"还没读到"这一态。读失败时留给订阅报告，不报两次。
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
    /// 附件文件到没到本机（图片、交付物随同步晚于对话到）：库里有这条附件、文件也在。附件表变化时重读；
    /// 行在滚动中一个个出现，不在主线程上当场读，没读到时按到了画。
    func observingArrival(of hash: String, in store: CueStore, into arrived: Binding<Bool?>) -> some View {
        observing(store, id: hash, into: arrived, immediately: false) { [files = store.files] store in
            try store.hasAttachment(hash) && files.fileURL(for: hash) != nil
        }
    }
}

extension View {
    /// 过了零点（"今天"按读的那一刻分的页面要重排、重读）。系统在它自己的线程上发这个通知：按主线程上的任务等，`action` 改的界面状态不跨线程。
    func onDayChange(_ action: @escaping () -> Void) -> some View {
        task { for await _ in NotificationCenter.default.notifications(named: .NSCalendarDayChanged) { action() } }
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
    /// 当场读到、还没交给订阅的那份。
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
        value = snapshot.value
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

// MARK: 分隔点

/// 一行元信息里隔开两段的"·"：只是版面，读屏不念（行要读的话由行自己的标签给）。颜色跟随外层，要淡一档的调用处自己加。
struct Dot: View {
    var body: some View { Text("·").accessibilityHidden(true) }
}

// MARK: 项目图标

struct ProjectGlyph: View {
    let project: Project?
    var size: CGFloat = 13
    @Environment(\.palette) private var palette

    var body: some View {
        Image(Self.icon(project))
            .font(.system(size: size, weight: .medium))
            // 项目还没同步到时是墨色，不借系统灰或系统强调色（侧栏列表会把 Label 的图标染成强调蓝）
            .foregroundStyle(project.map { palette.project($0.color) } ?? palette.ink2)
            .frame(width: size + 6)
            .accessibilityHidden(true) // 项目名总在旁边，图标只是装饰
    }

    /// 项目的图标；项目还没同步到时是文件夹。
    static func icon(_ project: Project?) -> Icon { .project(ProjectIcon(stored: project?.icon)) }
}

/// 项目图标的闭合表：项目表单只给这 24 种（Mac 表单一行 8 个，三行排满），写库写 `rawValue`；图在 `Icon.project`。
/// 库里存的值不迁移：表外的名字认不出，是文件夹（含没存图标的）。
nonisolated enum ProjectIcon: String, CaseIterable, Sendable {
    // rawValue 就是库里已存的名字（早先表单存的系统符号名，更早版本存的 lucide 名 rocket）：已有项目直接认得，不用映射
    case folder, sparkles, chat = "bubble.left.and.bubble.right", terminal, globe, hammer, book, target
    case briefcase, cart, megaphone, paintbrush, lightbulb, flag, cube, leaf
    case layers, camera, house, heart, star, music = "music.note", rocket, bolt

    init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .folder
    }

    /// 读屏与提示用的含义。
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

// MARK: 小件
extension LocalizedStringResource {
    /// 收界面字的参数拿到的是已经算好或用户写的字（项目名、会话标题、Agent 说的）：原样显示，不查目录。
    static func verbatim(_ text: String) -> Self { "\(text)" }
}

extension View {
    /// 菜单（`Menu`）的标签：里面的几样（图标、字、箭头）合成一个无障碍元素，读作 `spoken`。分开时 Mac 的菜单按钮按子视图拆成几颗，
    /// 菜单项只挂在第一颗下，读屏落在别的那颗上打开的是空壳。标签只有一个图标时不用它，给菜单本身 `accessibilityLabel` 就够。
    func menuLabel(_ spoken: LocalizedStringResource) -> some View { accessibilityElement(children: .ignore).accessibilityLabel(spoken) }
}

/// 列表里的大段标题（会话页的"现在""历史"）：页面的骨架，不比行里的字弱。左右缩进由所在列表给，同那一列卡片的左缘。
struct SectionTitle: View {
    let text: LocalizedStringResource
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text).font(Typography.sectionTitle).foregroundStyle(palette.ink).accessibilityAddTraits(.isHeader)
    }
}

/// 组头：小号半粗次要色，可带一个图标（"一直记着"的钉子）。按时间分的段（`TimeSection`：会话历史、记忆）与别的小组都用它。
/// 不用 `Label`：iOS 的 Label 给图标留一格固定宽，小图标与字之间空得太开。左右缩进与上下留白由所在列表给。
struct SectionLabel: View {
    let text: Dotted
    var icon: Icon?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(icon) }
            Text(text)
        }
        .font(Typography.label)
        .foregroundStyle(palette.ink3)
        // 图标是装饰：读屏只读文字（否则会读出"瞄准镜十字线"这类符号名），作为小节标题
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.spoken)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 全 App 唯一的"什么时候"写法（灵感、任务、回收站、Agent 会话、对话里的时间标记都用它）：一分钟内"刚刚"，一天内"N 分钟前""N 小时前"；
/// 再往前按日历（`day`）：昨天、一周内写星期、今年写月日、更早带年份。粗到小时为止，几小时前的事不写到分钟。都用系统格式，跟随界面语言。
/// 会话的计时会随时间刷新（`PiElapsed`）；灵感卡、回收站这些不加定时器，写的是打开时的值。
nonisolated enum DateLabel {
    static func short(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let elapsed = Int(now.timeIntervalSince(date))
        if elapsed < 60 { return String(localized: "刚刚") }
        if elapsed < 3600 { return relative(DateComponents(minute: -elapsed / 60), style: .abbreviated) }
        if elapsed < 86_400 { return relative(DateComponents(hour: -elapsed / 3600), style: .abbreviated) }
        return day(date, now: now, calendar: calendar)
    }

    /// 不是今天的那一天：昨天、一周内写星期、今年写月日、更早带年份。
    static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return relative(DateComponents(day: -1), style: .full)
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(monthDay) }
        return date.formatted(.dateTime.year().month(.defaultDigits).day())
    }

    /// "月/日"（今年里的日期、"更早"分组的周区间）。
    static let monthDay = Date.FormatStyle.dateTime.month(.defaultDigits).day()

    /// 系统的相对时间（"5 分钟前""昨天"），独立成一项时首字母大写。
    private static func relative(_ offset: DateComponents, style: RelativeDateTimeFormatter.UnitsStyle) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = style
        formatter.dateTimeStyle = .named
        formatter.formattingContext = .beginningOfSentence
        return formatter.localizedString(from: offset)
    }
}

/// 分段标题：名称 + 可选计数；读屏作为一个标题。
struct SectionHeader: View {
    let title: LocalizedStringResource
    var count: Int?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(palette.ink)
            if let count { Text("\(count)").font(.footnote.monospacedDigit()).foregroundStyle(palette.ink3).counting(count) }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
