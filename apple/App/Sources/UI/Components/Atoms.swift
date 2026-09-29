#if os(macOS)
import CuePi
import CueStore
import SwiftUI

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

// MARK: Pi 状态

extension PiAgentState {
    var label: String {
        switch self {
        case .idle: "空闲"
        case .thinking: "思考中"
        case .outputting: "输出中"
        case .tool(let name, let running, _): running.count > 1 ? "工具 · \(name) 等 \(running.count) 个" : "工具 · \(name)"
        case .waitingUser: "等你确认"
        case .done(let aborted): aborted ? "已中止" : "完成"
        case .error: "出错"
        }
    }

    /// 此刻在做什么的一句话：工具调用摘要、弹窗标题或错误信息；旧扩展不带详情时为 nil，界面只显示状态。
    var detail: String? {
        let text: String? = switch self {
        case .tool(_, _, let detail): detail
        case .waitingUser(_, let title): title
        case .error(let message): message
        default: nil
        }
        return text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    /// 详情是命令或路径（工具调用）时用等宽字。
    var detailIsCode: Bool {
        if case .tool = self { true } else { false }
    }

    var tint: Color {
        switch self {
        case .idle, .done: .secondary
        case .thinking, .outputting: .purple
        case .tool: .blue
        case .waitingUser: .orange
        case .error: .red
        }
    }

    /// 需要用户过去看一眼。
    var needsAttention: Bool {
        switch self {
        case .waitingUser, .error: true
        default: false
        }
    }
}

struct PiDot: View {
    let state: PiAgentState?
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(state?.tint ?? .secondary.opacity(0.5))
            .frame(width: size, height: size)
            .overlay {
                if state?.isBusy == true {
                    Circle().stroke((state?.tint ?? .clear).opacity(0.35), lineWidth: 3).scaleEffect(1.6)
                        .opacity(reduceMotion ? 0 : 1)
                }
            }
            .accessibilityLabel(state?.label ?? "已结束")
    }
}

/// 状态详情的一行文字；没有详情时不占位。
struct PiDetail: View {
    let state: PiAgentState
    var size: CGFloat = 12

    var body: some View {
        if let detail = state.detail {
            Text(detail)
                .font(.system(size: size, design: state.detailIsCode ? .monospaced : .default))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(detail)
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
    }

    /// Electron 版的图标名（lucide）映射到 SF Symbols；认不出的用文件夹。
    static func symbol(_ name: String?) -> String {
        guard let name else { return "tray" }
        if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil { return name }
        return lucide[name] ?? "folder"
    }

    static let choices = [
        "folder", "sparkles", "bubble.left.and.bubble.right", "terminal", "globe", "hammer", "book", "target",
        "briefcase", "cart", "megaphone", "paintbrush", "lightbulb", "flag", "cube", "leaf",
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

struct Keycap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 4))
    }
}

/// 分段标题：小号半粗次要色。
struct SectionLabel: View {
    let text: String
    var systemImage: String?
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let systemImage { Label(text, systemImage: systemImage) } else { Text(text) }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(palette.ink3)
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
#endif
