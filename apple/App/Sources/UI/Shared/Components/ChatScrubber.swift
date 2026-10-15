import CueText
import SwiftUI

/// 对话右缘的刻度滑条（会话页与 Cue 页同一个，`ChatColumn` 放）：你说的话是短线，上下文换了的地方（会话压缩、Cue 换新）是一个签名色的点，
/// 按先后排在右缘拇指够得着的那一段（可见区三成高处到"回到最新"圆钮上方），只看序号、不看行有多高（更早的那些还没排开）。
/// 平时淡淡地在那里（一眼看得出能跳），滚动时、手指按到刻度区时、Mac 上指针移到右缘时清楚起来，停手后淡回去。
/// 平时最多画 30 个刻度，更多时每个代表按序号均分的一段；拖动时以手指为中心鱼眼放大成逐条刻度、附近的刻度像程序坞那样变长，
/// 逐条轻触一下，旁边浮出那一条的第一行，松手（或点一下）跳过去。手势只在这一段窄条里，不碰代码块、表格的横向滚动、顶栏与返回手势。
/// 读屏上是一个可调节的元素：上下轻扫跳到上一处、下一处。不到两处时没有滑条。
struct ChatScrubber: View {
    let marks: [ChatMark]
    /// 用户正在滚对话。
    let scrolling: Bool
    let jump: (UUID) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 手指按着时在刻度区里的高度。
    @State private var finger: CGFloat?
    /// 停手后还留一会儿再淡回去。
    @State private var lingering = false
    /// 上一次跳到的那一处（读屏的上一处、下一处从它算）。记 id 不记序号：刻度随对话换（Cue 页只读最近 200 条，新消息进来最早的那处就掉出去），
    /// 记着的序号会指到别处或越界；那一处掉出去了就当没跳过。
    @State private var current: UUID?
    /// 指针停在右缘这条上（Mac、iPad 触控板）。
    @State private var hovering = false

    /// 会话的刻度：你发的话与换了上下文的地方（`PiNotice.changesContext`）。不到两处为空（没有滑条）。
    static func marks(_ entries: [PiChatEntry]) -> [ChatMark] {
        ChatMark.enough(entries.compactMap { entry in
            switch entry.role {
            case .user: ChatMark(id: entry.id, kind: .said, preview: ChatMark.firstLine(entry.text))
            case .notice(let notice) where notice.changesContext: ChatMark(id: entry.id, kind: .boundary, preview: entry.text)
            case .notice, .pi, .machine, .preview: nil
            }
        })
    }

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
    /// 刻度离右缘：手机上让开系统的滚动指示条（Mac 由 `ChatColumn` 让开窗口的滚动条）。
    #if os(iOS)
    private static let edge: CGFloat = 8
    #else
    private static let edge: CGFloat = 3
    #endif
    /// 刻度区在可见区里的上下边：上沿在三成高处（避开顶栏，进拇指够得着的区），下沿让开回复框右上方的"回到最新"圆钮。
    private static let bandTop: CGFloat = 0.3
    /// 平时（没在滚、没按着、指针不在上面）的不透明度：看得见、不抢字。
    private static let restOpacity = 0.35
    private static let linger: Duration = .milliseconds(900)

    private var active: Bool { finger != nil || scrolling || lingering || hovering }

    var body: some View {
        GeometryReader { proxy in
            let band = Band(height: proxy.size.height, count: marks.count)
            let pointed = finger.map(band.index(at:))
            Canvas { context, size in
                var last = -CGFloat.infinity
                for (index, y) in ticks(band) where y - last >= Self.minGap || index == pointed || marks[index].kind == .boundary {
                    last = y
                    // 离手指越近越长越粗越深（程序坞那样）：平时 7×1.5 的淡色短线，手指正下方 18×3、签名色（此刻的焦点）。
                    // 刻度贴着右缘（离边 `edge`），离气泡右缘（页边距 16）还有一段
                    let near = finger.map { max(0, 1 - abs(y - $0) / Self.reach) } ?? 0
                    let swell = near * near
                    if marks[index].kind == .boundary {
                        // 上下文换了的地方：一个签名色的点，放大时跟着变大
                        let side = 5 + 4 * swell
                        let rect = CGRect(x: size.width - Self.edge - 3.5 - side / 2, y: y - side / 2, width: side, height: side)
                        context.fill(Path(ellipseIn: rect), with: .color(palette.signature.opacity(index == pointed ? 1 : 0.85)))
                        continue
                    }
                    let length = 7 + 11 * swell, thickness = 1.5 + 1.5 * swell
                    let rect = CGRect(x: size.width - length - Self.edge, y: y - thickness / 2, width: length, height: thickness)
                    let color = index == pointed ? palette.signature : swell > 0 ? palette.ink.opacity(0.45 + 0.4 * swell) : palette.ink3
                    context.fill(Path(roundedRect: rect, cornerRadius: thickness / 2), with: .color(color))
                }
            }
            .opacity(active ? 1 : Self.restOpacity)
            .overlay(alignment: .topTrailing) {
                if let pointed, let finger {
                    preview(marks[pointed])
                        .offset(x: -(Self.width + 4), y: finger - 16)
                        .allowsHitTesting(false)
                }
            }
            .animation(reduceMotion ? nil : Motion.quick, value: active)
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
        .onHover { hovering = $0 }
        .task(id: scrolling || finger != nil) {
            // 停手后留一会儿再淡回去
            guard !scrolling, finger == nil else { lingering = true; return }
            guard (try? await Task.sleep(for: Self.linger)) != nil else { return }
            lingering = false
        }
        .accessibilityElement()
        .accessibilityLabel("对话刻度")
        .accessibilityValue(currentIndex.map { "第 \($0 + 1) 处，共 \(marks.count) 处：\(marks[$0].preview)" } ?? "共 \(marks.count) 处")
        .accessibilityAdjustableAction { direction in
            let from = currentIndex ?? marks.count
            switch direction {
            case .increment: go(to: min(from + 1, marks.count - 1))
            case .decrement: go(to: max(from - 1, 0))
            @unknown default: break
            }
        }
        .accessibilityActions {
            Button("上一处") { go(to: max((currentIndex ?? marks.count) - 1, 0)) }
            Button("下一处") { go(to: min((currentIndex ?? marks.count) + 1, marks.count - 1)) }
        }
    }

    /// 手指旁浮出的那一条：你的话是它的第一行，换了上下文的地方带一个同样的标。
    private func preview(_ mark: ChatMark) -> some View {
        HStack(spacing: 5) {
            if mark.kind == .boundary {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.signature)
            }
            Text(mark.preview).lineLimit(1)
        }
        .font(.footnote.weight(.medium)).foregroundStyle(palette.ink)
        .padding(.horizontal, 12).frame(height: 32)
        .glass(in: .capsule)
        .frame(maxWidth: 260, alignment: .trailing)
        .fixedSize()
    }

    private var currentIndex: Int? { current.flatMap { id in marks.firstIndex { $0.id == id } } }

    private func go(to index: Int) {
        current = marks[index].id
        jump(marks[index].id)
    }

    /// 此刻画哪些刻度、各在多高。平时最多 `visibleTicks` 个、每个代表均分的一段（换了上下文的点都画）；拖动时每条一个刻度，
    /// 按手指为中心做鱼眼变换（Sarkar–Brown：离手指越远越压紧，手指下的间距放大到 `focusPitch`），太密的由画的时候略过。
    private func ticks(_ band: Band) -> [(Int, CGFloat)] {
        guard let finger else {
            let shown = min(marks.count, Self.visibleTicks)
            var indices = Set((0..<shown).map { tick in shown > 1 ? (marks.count - 1) * tick / (shown - 1) : 0 })
            indices.formUnion(marks.indices.filter { marks[$0].kind == .boundary })
            return indices.sorted().map { ($0, band.y(of: $0)) }
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
}

/// 刻度滑条上的一处：你说的一句（短线），或上下文换了的地方（点）。
nonisolated struct ChatMark: Equatable, Sendable {
    enum Kind: Sendable { case said, boundary }

    let id: UUID
    let kind: Kind
    /// 拖到它时旁边浮出的一行。
    let preview: String

    /// 不到两处没有滑条：只有一处时无处可跳。
    static func enough(_ marks: [ChatMark]) -> [ChatMark] { marks.count < 2 ? [] : marks }

    /// 一条话的第一行文字；只有图片时写张数。
    static func firstLine(_ stored: String) -> String {
        if let line = CueFormat.plainText(stored).split(whereSeparator: \.isNewline).first { return line.trimmingCharacters(in: .whitespaces) }
        let images = CueFormat.imageHashes(in: stored).count
        return images > 0 ? "\(images) 张图片" : ""
    }
}
