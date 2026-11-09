import CueText
import SwiftUI

/// 阅读栏贴着边、右边距放不下刻度再隔一条缝（`crowded`，iPhone 与窄窗口）时平时不露也不接手指，滚动、指着时出来：常驻的话像一把尺子贴在气泡边上。
/// 键盘弹着时淡出让开（手机、iPad）：这时在写字，可见区只剩键盘上面一截，刻度挤在输入框旁边只是碍眼。
/// 手势只在这一段窄条里，不碰代码块、表格的横向滚动、顶栏与返回手势。
struct ChatScrubber: View {
    let marks: [ChatMark]
    let scrolling: Bool
    let crowded: Bool
    let jump: (UUID) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 刻度区的下沿还要让开浮在对话底上的回复框（Mac）。在这里读而不在 `ChatColumn` 读：它一读，回复框一变高矮整段对话都要重排。
    @Environment(\.chatBottomInset) private var bottomInset
    @State private var finger: CGFloat?
    @State private var lingering = false
    /// 上一次跳到的那一处（读屏的上一处、下一处从它算）。记 id 不记序号：刻度随对话换（Cue 页只读最近 200 条，新消息进来最早的那处就掉出去），
    /// 记着的序号会指到别处或越界；那一处掉出去了就当没跳过。
    @State private var current: UUID?
    @State private var hovering = false
    @State private var keyboard = false

    static func marks(_ entries: [PiChatEntry]) -> [ChatMark] {
        ChatMark.enough(entries.compactMap { entry in
            switch entry.role {
            case .user, .answer, .outgoing: ChatMark(id: entry.id, kind: .said, preview: ChatMark.firstLine(entry.text))
            case .notice(let notice) where notice.changesContext: ChatMark(id: entry.id, kind: .boundary, preview: notice.label)
            case .notice, .pi, .machine, .preview: nil
            }
        })
    }

    private static let visibleTicks = 30
    private static let maxPitch: CGFloat = 14
    private static let focusPitch: CGFloat = 7
    private static let minGap: CGFloat = 3
    private static let reach: CGFloat = 44
    static let width: CGFloat = 28
    /// 手机上让开系统的滚动指示条，Mac 上不贴着栏边（Mac 的对话不画系统滚动条，`ChatScroll`）。
    private static let edge: CGFloat = 8
    /// 上沿在三成高处：避开顶栏，进拇指够得着的区。
    private static let bandTop: CGFloat = 0.3
    private static let restOpacity = 0.35
    static let room: CGFloat = edge + restLength + 8
    private static let restLength: CGFloat = 7
    private static let linger: Duration = .milliseconds(900)

    private var active: Bool { finger != nil || scrolling || lingering || hovering }

    var body: some View {
        GeometryReader { proxy in
            let band = Band(height: proxy.size.height, count: marks.count)
            let pointed = finger.map(band.index(at:))
            let ticks = layout(band, width: proxy.size.width, pointed: pointed)
            // 刻度画成几条路径，不用 Canvas：第一次进页时它一张画布就要几毫秒。
            ZStack {
                Marks(ticks: ticks.filter { !$0.dot && !$0.pointed && $0.swell == 0 }).fill(palette.ink3)
                ForEach(Array(ticks.enumerated().filter { !$1.dot && !$1.pointed && $1.swell > 0 }), id: \.offset) { _, tick in
                    Marks(ticks: [tick]).fill(palette.ink3.mix(with: palette.ink, by: tick.swell))
                }
                Marks(ticks: ticks.filter { $0.dot && !$0.pointed }).fill(palette.ink2)
                Marks(ticks: ticks.filter(\.pointed)).fill(palette.signature)
            }
            .opacity(active ? 1 : crowded ? 0 : Self.restOpacity)
            .overlay(alignment: .topTrailing) {
                if let pointed, let finger {
                    preview(marks[pointed])
                        .offset(x: -(Self.width + 4), y: finger - 16)
                        .allowsHitTesting(false)
                }
            }
            .animation(Motion.spatial(Motion.fade, reduceMotion: reduceMotion), value: active)
            .contentShape(Rectangle().path(in: CGRect(x: 0, y: band.top, width: Self.width, height: band.bottom - band.top)))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in finger = min(max(value.location.y, band.top), band.bottom) }
                    .onEnded { value in
                        finger = nil
                        go(to: band.index(at: value.location.y))
                    })
            .sensoryFeedback(.selection, trigger: pointed) { _, new in new != nil }
            // 平时不露时也不接手指：贴右缘滚对话的拇指不会抓到看不见的刻度；滚起来它露出来，停手后还留一会儿可以抓
            .allowsHitTesting(active || !crowded)
        }
        .frame(width: Self.width)
        .padding(.bottom, bottomInset)
        .onHover { hovering = $0 }
        .task(id: scrolling || finger != nil) {
            guard !scrolling, finger == nil else { lingering = true; return }
            guard (try? await Task.sleep(for: Self.linger)) != nil else { return }
            lingering = false
        }
        .accessibilityElement()
        .accessibilityLabel("对话刻度")
        .accessibilityValue(currentIndex.map { String(localized: "第 \($0 + 1) 处，共 \(marks.count) 处：\(marks[$0].preview)") } ?? String(localized: "共 \(marks.count) 处"))
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
        .opacity(keyboard ? 0 : 1)
        .allowsHitTesting(!keyboard)
        .readerHidden(keyboard)
        .animation(Motion.spatial(Motion.fade, reduceMotion: reduceMotion), value: keyboard)
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboard = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboard = false }
        #endif
    }

    private func preview(_ mark: ChatMark) -> some View {
        HStack(spacing: Spacing.glyph) {
            if mark.kind == .boundary {
                Image(.renew).font(Glyph.mark).foregroundStyle(palette.ink2)
            }
            Text(mark.preview).lineLimit(1)
        }
        .font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink)
        .padding(.horizontal, Spacing.group).frame(height: 32)
        .glass(in: .capsule)
        .frame(maxWidth: 260, alignment: .trailing)
        .fixedSize()
    }

    private var currentIndex: Int? { current.flatMap { id in marks.firstIndex { $0.id == id } } }

    private func go(to index: Int) {
        current = marks[index].id
        jump(marks[index].id)
    }

    /// 拖动时按手指为中心做鱼眼变换（Sarkar–Brown：离手指越远越压紧，手指下的间距放大到 `focusPitch`）。
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

    nonisolated fileprivate struct Tick: Sendable {
        let rect: CGRect
        let dot: Bool
        let pointed: Bool
        let swell: CGFloat
    }

    private func layout(_ band: Band, width: CGFloat, pointed: Int?) -> [Tick] {
        var last = -CGFloat.infinity
        return ticks(band).compactMap { index, y in
            let dot = marks[index].kind == .boundary
            guard y - last >= Self.minGap || index == pointed || dot else { return nil }
            last = y
            let swell = finger.map { pow(max(0, 1 - abs(y - $0) / Self.reach), 2) } ?? 0
            if dot {
                let side = 5 + 4 * swell
                return Tick(rect: CGRect(x: width - Self.edge - 3.5 - side / 2, y: y - side / 2, width: side, height: side), dot: true, pointed: index == pointed, swell: swell)
            }
            let length = Self.restLength + 11 * swell, thickness = 1.5 + 1.5 * swell
            return Tick(rect: CGRect(x: width - length - Self.edge, y: y - thickness / 2, width: length, height: thickness), dot: false, pointed: index == pointed, swell: swell)
        }
    }

    private struct Band {
        let top: CGFloat
        let bottom: CGFloat
        let count: Int
        let step: CGFloat
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

nonisolated private struct Marks: Shape {
    let ticks: [ChatScrubber.Tick]

    func path(in rect: CGRect) -> Path {
        Path { path in
            for tick in ticks {
                if tick.dot { path.addEllipse(in: tick.rect) } else { path.addRoundedRect(in: tick.rect, cornerSize: CGSize(width: tick.rect.height / 2, height: tick.rect.height / 2)) }
            }
        }
    }
}

nonisolated struct ChatMark: Equatable, Sendable {
    enum Kind: Sendable { case said, boundary }

    let id: UUID
    let kind: Kind
    let preview: String

    /// 只有一处时无处可跳。
    static func enough(_ marks: [ChatMark]) -> [ChatMark] { marks.count < 2 ? [] : marks }

    static func firstLine(_ stored: String) -> String {
        if let line = CueFormat.plainText(stored).split(whereSeparator: \.isNewline).first { return line.trimmingCharacters(in: .whitespaces) }
        let images = CueFormat.parse(stored).count { if case .image = $0 { true } else { false } }
        return images > 0 ? String(localized: "\(images) 张图片") : ""
    }
}
