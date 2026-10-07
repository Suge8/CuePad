#if os(iOS)
import SwiftUI

/// 会话右缘的刻度滑条：一条你发的话一个刻度，按先后以固定的小间距从上往下排（只看序号，不看还没排版的行有多高——倒置的
/// 懒加载里那些高度是估的；条数多到排不下时间距收紧到正好排满）。平时看不见，滚动时或手指按到右缘时淡入，停手后淡出；
/// 拖着走时手指附近的刻度像程序坞那样放大，逐个刻度轻触一下，旁边浮出那条的第一行，松手（或点一下）跳过去。手势只在右缘这一窄条里，不碰代码块、表格的横向滚动与左缘的返回手势。读屏上是一个可调节的元素：
/// 上下轻扫跳到上一条、下一条你的话。
struct ChatScrubber: View {
    let marks: [ChatMark]
    /// 用户正在滚对话。
    let scrolling: Bool
    let jump: (UUID) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 手指按着时的高度。
    @State private var finger: CGFloat?
    /// 停手后还留一会儿再淡出。
    @State private var lingering = false
    /// 读屏上一次跳到的（上一条、下一条从它算）。
    @State private var current: Int?

    /// 你发的话（按先后）：刻度与预览。不到 `minimum` 条时没有刻度。
    static func marks(_ entries: [PiChatEntry]) -> [ChatMark] {
        let marks = entries.filter(\.isUser).map { ChatMark(id: $0.id, preview: firstLine($0.text)) }
        return marks.count < minimum ? [] : marks
    }

    private static let minimum = 6
    /// 右缘接住手指的宽度。
    static let width: CGFloat = 24
    /// 刻度区上下留的边。
    private static let inset: CGFloat = 16
    /// 相邻刻度的间距。
    private static let pitch: CGFloat = 7
    /// 放大波及的范围（离手指多远的刻度还跟着放大）。
    private static let reach: CGFloat = 44
    private static let linger: Duration = .milliseconds(900)

    private var visible: Bool { finger != nil || scrolling || lingering }

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let pointed = finger.map { index(at: $0, height) }
            Canvas { context, size in
                for index in marks.indices {
                    // 离手指越近越长越粗越深（平时 7×1.5 的淡色短线，手指正下方 18×3 的墨色）
                    let near = finger.map { max(0, 1 - abs(y(index, height) - $0) / Self.reach) } ?? 0
                    let swell = near * near
                    let length = 7 + 11 * swell, thickness = 1.5 + 1.5 * swell
                    let rect = CGRect(x: size.width - length - 4, y: y(index, height) - thickness / 2, width: length, height: thickness)
                    let color = index == pointed ? palette.ink : swell > 0 ? palette.ink.opacity(0.45 + 0.4 * swell) : palette.ink3
                    context.fill(Path(roundedRect: rect, cornerRadius: thickness / 2), with: .color(color))
                }
            }
            .overlay(alignment: .topTrailing) {
                if let pointed {
                    Text(marks[pointed].preview)
                        .font(.footnote.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1)
                        .padding(.horizontal, 12).frame(height: 32)
                        .glass(in: .capsule)
                        .frame(maxWidth: proxy.size.width + 220, alignment: .trailing)
                        .fixedSize()
                        .offset(x: -(Self.width + 4), y: y(pointed, height) - 16)
                        .allowsHitTesting(false)
                }
            }
            .opacity(visible ? 1 : 0)
            .animation(reduceMotion ? nil : Motion.quick, value: visible)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in finger = value.location.y }
                    .onEnded { value in
                        finger = nil
                        go(to: index(at: value.location.y, height))
                    })
            .sensoryFeedback(.selection, trigger: pointed) { _, new in new != nil }
        }
        .frame(width: Self.width)
        .task(id: scrolling || finger != nil) {
            // 停手后留一会儿再淡出
            guard !scrolling, finger == nil else { lingering = true; return }
            try? await Task.sleep(for: Self.linger)
            lingering = false
        }
        .accessibilityElement()
        .accessibilityLabel("我发的话")
        .accessibilityValue(current.map { "第 \($0 + 1) 条，共 \(marks.count) 条：\(marks[$0].preview)" } ?? "共 \(marks.count) 条")
        .accessibilityAdjustableAction { direction in
            let from = current ?? marks.count
            switch direction {
            case .increment: go(to: min(from + 1, marks.count - 1))
            case .decrement: go(to: max(from - 1, 0))
            @unknown default: break
            }
        }
        .accessibilityActions {
            Button("上一条我的话") { go(to: max((current ?? marks.count) - 1, 0)) }
            Button("下一条我的话") { go(to: min((current ?? marks.count) + 1, marks.count - 1)) }
        }
    }

    private func go(to index: Int) {
        current = index
        jump(marks[index].id)
    }

    /// 相邻刻度的间距：固定的小间距，排不下时收紧到正好排满。
    private func spacing(_ height: CGFloat) -> CGFloat {
        min(Self.pitch, max(height - 2 * Self.inset, 0) / CGFloat(max(marks.count - 1, 1)))
    }

    /// 第 `index` 个刻度的高度：最早的在最上。
    private func y(_ index: Int, _ height: CGFloat) -> CGFloat {
        Self.inset + spacing(height) * CGFloat(index)
    }

    private func index(at y: CGFloat, _ height: CGFloat) -> Int {
        let step = max(spacing(height), 1)
        return min(max(Int(((y - Self.inset) / step).rounded()), 0), marks.count - 1)
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

/// 刻度滑条上的一个刻度：你发的一条话。
nonisolated struct ChatMark: Equatable {
    let id: UUID
    let preview: String
}
#endif
