import CueText
import SwiftUI

/// 对话目录：对话右缘一列记号，你说过的一句一道短横、换了上下文（压缩）一颗小点；展开成一块面板，一行一句（这句话的第一行），点一行当帧跳过去（`EdgeIndex`）。
/// 此刻读到的那一句（可见区上三分之一那条线落在的那一条往前最近的一句，`ChatReading`）用正常墨色标出，其余淡着。
/// 阅读栏贴着边、右边距放不下记号再隔一条缝（`crowded`，iPhone 与窄窗口）时平时不露也不接手指，滚动时出来、停手后再留一会儿：常驻的话像一把尺子贴在气泡边上。
/// 键盘弹着时淡出让开（手机、iPad）：这时在写字，可见区只剩键盘上面一截，记号挤在输入框旁边只是碍眼。
struct ChatIndex: View {
    let marks: [ChatMark]
    let ids: [UUID]
    let reading: ChatReading
    let scrolling: Bool
    let crowded: Bool
    let jump: (UUID) -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 目录的下沿还要让开浮在对话底上的回复框（Mac）。在这里读而不在 `ChatColumn` 读：它一读，回复框一变高矮整段对话都要重排。
    @Environment(\.chatBottomInset) private var bottomInset
    @ScaledMetric(relativeTo: .body) private var row: CGFloat = 32
    @State private var lingering = false
    @State private var open = false
    @State private var keyboard = false

    private static let width: CGFloat = 16
    private static let dash: CGFloat = 8
    private static let dot: CGFloat = 5
    private static let pitch: CGFloat = 10
    private static let visibleMarks = 30
    private static let restOpacity = 0.35
    static let room: CGFloat = Spacing.tight + width + Spacing.item
    private static let linger: Duration = .milliseconds(2500)

    private var shown: Bool { !keyboard && (!crowded || scrolling || lingering || open) }

    var body: some View {
        EdgeIndex(
            groups: [marks], edge: .trailing, metrics: .init(width: Self.width, pitch: Self.pitch, tall: row, short: row, panel: 320),
            shut: .marks(Self.visibleMarks), current: current,
            label: "对话目录", spoken: { ($0.preview, "") }, choose: { jump($0.id) }, expandedChanged: { open = $0 },
            mark: mark, words: words, overflow: { _ in EmptyView() })
            .padding(.top, JumpToNewest.clearance)
            .padding(.bottom, bottomInset + JumpToNewest.clearance)
            .opacity(shown ? 1 : 0)
            // 平时不露时也不接手指：贴右缘滚对话的拇指不会抓到看不见的记号；滚起来它露出来，停手后还留一会儿可以抓
            .allowsHitTesting(shown)
            .readerHidden(keyboard)
            .animation(Motion.spatial(Motion.fade, reduceMotion: reduceMotion), value: shown)
            .task(id: scrolling || open) {
                guard !scrolling, !open else { lingering = true; return }
                guard (try? await Task.sleep(for: Self.linger)) != nil else { return }
                lingering = false
            }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboard = true }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboard = false }
            #endif
    }

    private var current: UUID? {
        guard let at = reading.id else { return nil }
        let said = Set(marks.map(\.id))
        var last: UUID?
        for id in ids {
            if said.contains(id) { last = id }
            if id == at { return last }
        }
        return nil
    }

    private func mark(_ mark: ChatMark, _ cell: EdgeIndexCell) -> some View {
        let ink = cell.current ? palette.ink : mark.kind == .boundary ? palette.ink2 : palette.ink3
        return Group {
            if mark.kind == .boundary {
                Circle().frame(width: Self.dot, height: Self.dot)
            } else {
                Capsule().frame(width: Self.dash, height: cell.current ? 2.5 : 1.5)
            }
        }
        .foregroundStyle(ink)
        .opacity(cell.current || cell.expanded || scrolling || lingering ? 1 : Self.restOpacity)
    }

    private func words(_ mark: ChatMark, _ cell: EdgeIndexCell) -> some View {
        HStack(spacing: Spacing.glyph) {
            if mark.kind == .boundary { Image(.renew).font(Glyph.mark) }
            Text(verbatim: mark.preview).lineLimit(1).truncationMode(.tail)
        }
        .font(Typography.secondary)
        .foregroundStyle(mark.kind == .boundary ? palette.ink2 : palette.ink)
        .padding(.trailing, Spacing.tight)
    }
}

@Observable final class ChatReading {
    var id: UUID?
}

nonisolated struct ChatMark: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case said, boundary }

    let id: UUID
    let kind: Kind
    let preview: String

    static func of(_ entries: [ChatEntry]) -> [ChatMark] {
        enough(entries.compactMap { entry in
            switch entry.role {
            case .user, .answer, .outgoing: ChatMark(id: entry.id, kind: .said, preview: firstLine(entry.text))
            case .notice(let notice) where notice.changesContext: ChatMark(id: entry.id, kind: .boundary, preview: notice.label)
            case .notice, .pi, .machine, .preview: nil
            }
        })
    }

    static func enough(_ marks: [ChatMark]) -> [ChatMark] { marks.count < 2 ? [] : marks }

    static func firstLine(_ stored: String) -> String {
        if let line = CueFormat.plainText(stored).split(whereSeparator: \.isNewline).first { return line.trimmingCharacters(in: .whitespaces) }
        let images = CueFormat.parse(stored).count { if case .image = $0 { true } else { false } }
        return images > 0 ? String(localized: "\(images) 张图片") : ""
    }
}

extension EnvironmentValues {
    @Entry var chatReading: ChatReading?
}
