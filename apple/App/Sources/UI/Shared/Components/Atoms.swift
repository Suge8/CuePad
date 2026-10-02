import CueStore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: 订阅 Store

extension View {
    /// 订阅 Store：`id` 变化时重新订阅；每次变更重读后写入 `value`。读失败交给 `onError`。
    func observing<T: Sendable>(
        _ store: CueStore, _ tables: Set<StoreTable>, id: some Equatable = 0, into value: Binding<T?>,
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
// MARK: 项目图标

struct ProjectGlyph: View {
    let project: Project?
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: Self.symbol(project?.icon))
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(project.map { Palette.projectTint($0.color) } ?? .secondary)
            .frame(width: size + 6)
            .accessibilityHidden(true) // 项目名总在旁边，图标只是装饰
    }

    /// Electron 版的图标名（lucide）映射到 SF Symbols；认不出的用文件夹。
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
    let text: String
    var systemImage: String?
    @Environment(\.palette) private var palette

    /// iOS 跟随动态字体；Mac 用固定的小号字。
    private static var font: Font {
        #if os(iOS)
        .caption.weight(.semibold)
        #else
        .system(size: 11, weight: .semibold)
        #endif
    }

    var body: some View {
        Group {
            if let systemImage { Label(text, systemImage: systemImage) } else { Text(text) }
        }
        .font(Self.font)
        .foregroundStyle(palette.ink3)
        // 图标是装饰：读屏只读文字（否则会读出"瞄准镜十字线"这类符号名），作为小节标题
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 列表与卡片上的日期：今天显示时刻，一周内显示星期，今年显示月日，更早带年份。
enum DateLabel {
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func short(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return clock.string(from: date) }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let chinese = Locale(identifier: "zh_CN")
        if days < 7 { return date.formatted(.dateTime.weekday(.abbreviated).locale(chinese)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.defaultDigits).day().locale(chinese))
        }
        return date.formatted(.dateTime.year().month(.defaultDigits).day().locale(chinese))
    }
}
