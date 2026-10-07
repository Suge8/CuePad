#if os(iOS)
import SwiftUI

/// 会话右缘的刻度滑条：你发的话按先后排在右缘拇指够得着的那一段（可见区三成高处到回复框上方），只看序号、不看还没排版的行
/// 有多高（倒置的懒加载里那些高度是估的）。平时最多画 30 个刻度，更多时每个代表按序号均分的一段；拖动时以手指为中心
/// 鱼眼放大成逐条刻度、附近的刻度像程序坞那样变长，逐条轻触一下，旁边浮出那一条的第一行，松手（或点一下）跳过去。
/// 平时看不见，滚动时或手指按到刻度区时淡入，停手后淡出。手势只在这一段窄条里，不碰代码块、表格的横向滚动、顶栏与返回手势。
/// 读屏上是一个可调节的元素：上下轻扫跳到上一条、下一条你的话。
struct ChatScrubber: View {
    let marks: [ChatMark]
    /// 用户正在滚对话。
    let scrolling: Bool
    let jump: (UUID) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 手指按着时在刻度区里的高度。
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
    /// 平时最多画这么多个刻度；更多时每个刻度代表按序号均分的一段。
    private static let visibleTicks = 30
    /// 刻度最大间距；条数少时刻度贴着刻度区的下沿（拇指那头）排。
    private static let maxPitch: CGFloat = 14
    /// 拖动时手指下逐条刻度的间距（鱼眼放大到这么疏）。
    private static let focusPitch: CGFloat = 7
    /// 画出来的相邻两个刻度至少隔这么远，更密的略过。
    private static let minGap: CGFloat = 3
    /// 放大波及的范围（离手指多远的刻度还跟着变长）。
    private static let reach: CGFloat = 44
    /// 右缘接住手指的宽度。
    static let width: CGFloat = 28
    /// 刻度区在可见区里的上下边：上沿在三成高处（避开顶栏，进拇指够得着的区），下沿让开回复框右上方的"回到最新"圆钮。
    private static let bandTop: CGFloat = 0.3
    private static let linger: Duration = .milliseconds(900)

    private var visible: Bool { finger != nil || scrolling || lingering }

    var body: some View {
        GeometryReader { proxy in
            let band = Band(height: proxy.size.height, count: marks.count)
            let pointed = finger.map(band.index(at:))
            Canvas { context, size in
                var last = -CGFloat.infinity
                for (index, y) in ticks(band) where y - last >= Self.minGap || index == pointed {
                    last = y
                    // 离手指越近越长越粗越深（程序坞那样）：平时 7×1.5 的淡色短线，手指正下方 18×3 的墨色
                    let near = finger.map { max(0, 1 - abs(y - $0) / Self.reach) } ?? 0
                    let swell = near * near
                    let length = 7 + 11 * swell, thickness = 1.5 + 1.5 * swell
                    let rect = CGRect(x: size.width - length - 6, y: y - thickness / 2, width: length, height: thickness)
                    let color = index == pointed ? palette.ink : swell > 0 ? palette.ink.opacity(0.45 + 0.4 * swell) : palette.ink3
                    context.fill(Path(roundedRect: rect, cornerRadius: thickness / 2), with: .color(color))
                }
            }
            .overlay(alignment: .topTrailing) {
                if let pointed, let finger {
                    Text(marks[pointed].preview)
                        .font(.footnote.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1)
                        .padding(.horizontal, 12).frame(height: 32)
                        .glass(in: .capsule)
                        .frame(maxWidth: 260, alignment: .trailing)
                        .fixedSize()
                        .offset(x: -(Self.width + 4), y: finger - 16)
                        .allowsHitTesting(false)
                }
            }
            .opacity(visible ? 1 : 0)
            .animation(reduceMotion ? nil : Motion.quick, value: visible)
            // 只有刻度区接手指：上面的顶栏区与下面的回复框附近照常滚对话
            .contentShape(Rectangle().path(in: CGRect(x: 0, y: band.top, width: Self.width, height: band.bottom - band.top)))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in finger = min(max(value.location.y, band.top), band.bottom) }
                    .onEnded { value in
                        finger = nil
                        go(to: band.index(at: value.location.y))
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

    /// 此刻画哪些刻度、各在多高。平时最多 `visibleTicks` 个、每个代表均分的一段；拖动时每条一个刻度，
    /// 按手指为中心做鱼眼变换（Sarkar–Brown：离手指越远越压紧，手指下的间距放大到 `focusPitch`），太密的由画的时候略过。
    private func ticks(_ band: Band) -> [(Int, CGFloat)] {
        guard let finger else {
            let shown = min(marks.count, Self.visibleTicks)
            return (0..<shown).map { tick in
                let index = shown > 1 ? (marks.count - 1) * tick / (shown - 1) : 0
                return (index, band.y(of: index))
            }
        }
        let zoom = max(0, Self.focusPitch / band.step - 1)
        return marks.indices.map { index in
            let y = band.y(of: index)
            let (edge, sign): (CGFloat, CGFloat) = y >= finger ? (band.bottom, 1) : (band.top, -1)
            let reach = abs(edge - finger)
            guard reach > 0 else { return (index, y) }
            let x = abs(y - finger) / reach
            return (index, finger + sign * reach * (zoom + 1) * x / (zoom * x + 1))
        }
    }

    /// 刻度区：上下边、所有刻度不放大时的排布（按序号均匀，条数少时间距不超过 `maxPitch`、贴着下沿）。
    private struct Band {
        let top: CGFloat
        let bottom: CGFloat
        let count: Int
        /// 相邻两条不放大时的间距。
        let step: CGFloat
        /// 第一条（最早的）所在的高度。
        let first: CGFloat

        init(height: CGFloat, count: Int) {
            top = height * ChatScrubber.bandTop
            bottom = max(top, height - JumpToNewest.clearance)
            self.count = count
            let shown = min(count, ChatScrubber.visibleTicks)
            let pitch = min(ChatScrubber.maxPitch, (bottom - top) / CGFloat(max(shown - 1, 1)))
            let span = pitch * CGFloat(shown - 1)
            step = count > 1 ? span / CGFloat(count - 1) : 0
            first = bottom - span
        }

        func y(of index: Int) -> CGFloat { first + step * CGFloat(index) }

        func index(at y: CGFloat) -> Int {
            guard step > 0 else { return 0 }
            return min(max(Int(((y - first) / step).rounded()), 0), count - 1)
        }
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
