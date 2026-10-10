import CueStore
import enum CueStore.Table  // 盖过 SwiftUI.Table
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: 订阅 Store

extension View {
    /// 订阅 Store：`id` 变化时重新订阅；每次变更重读后写入 `value`。读失败交给 `onError`。
    func observing<T: Sendable>(
        _ store: CueStore, _ tables: Set<Table>, id: some Equatable = 0, into value: Binding<T?>,
        onError: @escaping (any Error) -> Void = { _ in },
        _ read: @escaping @Sendable (isolated CueStore) throws -> T
    ) -> some View {
        task(id: id) {
            do {
                for try await next in store.observe(tables, read) { value.wrappedValue = next }
            } catch is CancellationError {
            } catch {
                onError(error)
            }
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
        // 旁边总有项目名：图标只是装饰，读屏不念它的系统名
        Image(systemName: Self.symbol(project?.icon))
            .accessibilityHidden(true)
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(project.map { Palette.projectTint($0.color) } ?? .secondary)
            // 深色下提亮一档：偏灰、偏暗的项目色（如 #8A8A84）的细线图标在深底与玻璃上几乎看不见
            .brightness(palette.dark ? 0.18 : 0)
            .frame(width: size + 6)
            .accessibilityHidden(true) // 项目名总在旁边，图标只是装饰
    }

    /// 项目图标存的是 lucide 图标名，映射到 SF Symbols；认不出的用文件夹。
    static func symbol(_ name: String?) -> String {
        guard let name else { return "tray" }
        if isSymbol(name) { return name }
        return lucide[name] ?? "folder"
    }

    /// 新建项目时可选的图标：SF Symbol 名 → 读屏与提示用的中文含义。
    private static func isSymbol(_ name: String) -> Bool {
        #if canImport(UIKit)
        UIImage(systemName: name) != nil
        #else
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #endif
    }

    static let choices: [(symbol: String, name: String)] = [
        ("folder", "文件夹"), ("sparkles", "闪光"), ("bubble.left.and.bubble.right", "对话"), ("terminal", "终端"),
        ("globe", "地球"), ("hammer", "锤子"), ("book", "书"), ("target", "靶心"),
        ("briefcase", "公文包"), ("cart", "购物车"), ("megaphone", "喇叭"), ("paintbrush", "画笔"),
        ("lightbulb", "灯泡"), ("flag", "旗帜"), ("cube", "方块"), ("leaf", "叶子"),
    ]

    private static let lucide: [String: String] = [
        "target": "target", "book": "book", "folder": "folder", "star": "star", "heart": "heart",
        "code": "chevron.left.forwardslash.chevron.right", "terminal": "terminal", "globe": "globe",
        "briefcase": "briefcase", "lightbulb": "lightbulb", "rocket": "paperplane", "flag": "flag",
        "zap": "bolt", "coffee": "cup.and.saucer", "music": "music.note", "camera": "camera",
        "message-circle": "bubble.left", "messages-square": "bubble.left.and.bubble.right",
        "shopping-bag": "bag", "megaphone": "megaphone", "box": "shippingbox", "layers": "square.stack.3d.up",
        "sparkles": "sparkles", "pen-tool": "pencil.tip", "palette": "paintpalette", "home": "house",
    ]
}

// MARK: 小件
/// 分段标题：小号半粗次要色。
struct SectionLabel: View {
    let text: Dotted
    var systemImage: String?
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let systemImage { Label { Text(text) } icon: { Image(systemName: systemImage) } } else { Text(text) }
        }
        .font(Typography.label)
        .foregroundStyle(palette.ink3)
        // 图标是装饰：读屏只读文字（否则会读出"瞄准镜十字线"这类符号名），作为小节标题
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.spoken)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 全 App 唯一的"什么时候"写法（灵感、任务、回收站、Agent 会话都用它）：一分钟内"刚刚"，一小时内"N 分钟前"，一天内"N 小时前"；
/// 再往前按日历：昨天、一周内写星期、今年写月日、更早带年份。粗到小时为止，几小时前的事不写到分钟。
/// 会话的计时会随时间刷新（`PiElapsed`）；灵感卡、回收站这些不加定时器，写的是打开时的值。
nonisolated enum DateLabel {
    static func short(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3600 { return "\(Int(elapsed) / 60) 分钟前" }
        if elapsed < 86_400 { return "\(Int(elapsed) / 3600) 小时前" }
        if calendar.isDate(date, inSameDayAs: calendar.date(byAdding: .day, value: -1, to: now) ?? now) { return "昨天" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let chinese = Locale(identifier: "zh_CN")
        if days < 7 { return date.formatted(.dateTime.weekday(.abbreviated).locale(chinese)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.defaultDigits).day().locale(chinese))
        }
        return date.formatted(.dateTime.year().month(.defaultDigits).day().locale(chinese))
    }
}

/// 分段标题：名称 + 可选计数；读屏作为一个标题。
struct SectionHeader: View {
    let title: String
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
