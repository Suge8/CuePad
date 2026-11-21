import CueStore
import SwiftUI

/// 舞台上云下那几件：你不在时攒下的、点一下就到的，至多三行，按先后：Cue 没读的话（它自己醒来做的事落在这里）、做完了结果你还没看的、Cue 留给你回的会话。
/// 拍板不在这里：拍板卡就在下面，一件事一处。都没有时只剩气泡里那一句（Cue 此刻的样子）。
nonisolated struct CueBrief: Equatable, Sendable {
    struct Line: Equatable, Identifiable, Sendable {
        enum Go: Equatable, Sendable {
            case session(String)
            /// 对话里的这一条：滚过去从它读起，舞台留在尽头。
            case message(UUID)
        }

        let id: String
        let icon: Icon
        let tone: CueNow.Tone?
        let title: String
        let detail: String
        var shot: CueShown?
        let go: Go
    }

    static let limit = 3
    var lines: [Line] = []

    /// 要另查库的两种，至多 `room` 行；新消息那一行页按对话当场排在最前（`said`），不经这里：它跟着对话变，不等重读。
    static func read(replies: [CueNow.Item], room: Int, from store: isolated CueStore) throws -> CueBrief {
        var lines: [Line] = []
        if room > 0, let task = try store.unseenDone(), let session = task.piSessionID {
            let shot = try store.cueResultShots(of: [task])[task.id]?.first
            let preview = try shot.flatMap { try store.previews([$0.preview])[$0.preview] }
            lines.append(Line(
                id: "done/\(task.id)", icon: .done, tone: .done, title: task.heading, detail: try gist(session, from: store) ?? CueNow.Item.Kind.done.label,
                shot: preview.flatMap { preview in shot.map { CueShown(preview: preview, look: $0.look) } }, go: .session(session)))
        }
        for item in replies.prefix(max(0, room - lines.count)) {
            let session = String(item.id.dropFirst("reply/".count))
            lines.append(Line(
                id: item.id, icon: .replied, tone: .reply, title: item.name, detail: try gist(session, from: store) ?? item.kind.label, go: .session(session)))
        }
        return CueBrief(lines: lines)
    }

    /// 新消息：几条、头一条的第一句，点了滚过去从它读起。
    static func said(_ thread: CueThread) -> Line? {
        let unread = thread.messages.filter { $0.author == .known(.cue) && thread.unread.contains($0.id) }
        guard let first = unread.first else { return nil }
        return Line(
            id: "said", icon: .said, tone: nil, title: String(localized: "\(unread.count) 条新消息"), detail: firstSentence(first.text), go: .message(first.id))
    }

    private static func gist(_ session: String, from store: isolated CueStore) throws -> String? {
        try store.sessionState(session)?.lastReply.map(firstSentence).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func firstSentence(_ text: String) -> String {
        let plain = MarkdownBlock.plainText(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = plain.firstIndex(where: { "。！？!?\n".contains($0) }) else { return plain }
        return String(plain[...end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 气泡：一块玻璃，尾巴朝上指着云上的 Cue（浮在网点天空上的表面用系统玻璃，字压在花的云上时玻璃垫着底才读得清）。
/// 上面一句是 Cue 此刻的样子（`CueNow.quietLine`，出错着胭脂），下面各行是一颗钮。没有可列的时只剩那一句，气泡自己缩小。
struct CueBriefBubble: View {
    let beat: CueBeat
    let status: String
    let lines: [CueBrief.Line]
    let row: CGFloat
    let open: (CueBrief.Line) -> Void
    @Environment(\.palette) private var palette

    /// 比对话的读宽窄：宽屏上铺满读宽就成了一条横幅，不像谁说出来的。
    static let width: CGFloat = 440
    private static let shot: CGFloat = 40

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(verbatim: status)
                .font(lines.isEmpty ? Typography.bodyStrong : Typography.secondary)
                .foregroundStyle(beat == .failed ? palette.failure : lines.isEmpty ? palette.ink : palette.ink2)
                .lineLimit(2)
                .padding(.horizontal, Spacing.item)
            if !lines.isEmpty {
                VStack(spacing: 0) {
                    ForEach(lines) { line in row(line).transition(.opacity) }
                }
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, Spacing.item)
        .padding(.top, Spacing.group + SpeechShape.tail).padding(.bottom, lines.isEmpty ? Spacing.group : Spacing.item)
        .frame(maxWidth: lines.isEmpty ? nil : .infinity, alignment: .leading)
        .glass(in: SpeechShape(), interactive: !lines.isEmpty)
        .contentShape(SpeechShape())
    }

    private func row(_ line: CueBrief.Line) -> some View {
        Button { open(line) } label: {
            HStack(spacing: Spacing.group) {
                Image(line.icon).font(Glyph.large).foregroundStyle(line.tone?.color(palette) ?? palette.ink2).frame(width: Glyph.largeSize)
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text(verbatim: line.title).font(Typography.bodyStrong).foregroundStyle(palette.ink).lineLimit(1)
                    Text(verbatim: line.detail).font(Typography.secondary).foregroundStyle(palette.ink3).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let shot = line.shot {
                    // 只给人认出是哪一张：点它与点这一行一样，成果在会话里看全
                    DeliverableTile(preview: shot.preview, label: shot.look, shape: .shot(side: Self.shot, chosen: false), captioned: false,
                                    zoom: PreviewZoomKey(group: "stage", preview: shot.id)) { _ in }
                        .allowsHitTesting(false)
                } else {
                    Chevron(.forward).foregroundStyle(palette.ink3)
                }
            }
            .padding(.horizontal, Spacing.item)
            .frame(height: row)
            .contentShape(.rect(cornerRadius: Radius.row))
        }
        .buttonStyle(PressStyle())
    }
}

/// 气泡的形：圆角的身子，上沿正中一个小尖朝上。尖的两肩与顶都是圆的，同系统气泡的尾巴：直角的三角像贴上去的。
/// 尾巴的高算在框里（`tail`），尖顶在框的上沿。
nonisolated struct SpeechShape: Shape {
    static let tail: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        let tail = Self.tail
        let body = CGRect(x: rect.minX, y: rect.minY + tail, width: rect.width, height: rect.height - tail)
        let path = Path(roundedRect: body, cornerRadius: min(Radius.sheet, body.height / 2), style: .continuous)
        let mid = rect.midX, half = tail * 0.9, top = rect.minY, base = body.minY
        var tip = Path()
        tip.move(to: CGPoint(x: mid - half - tail, y: base))
        tip.addCurve(to: CGPoint(x: mid - tail * 0.25, y: top + tail * 0.12), control1: CGPoint(x: mid - half, y: base), control2: CGPoint(x: mid - tail * 0.55, y: top + tail * 0.35))
        tip.addQuadCurve(to: CGPoint(x: mid + tail * 0.25, y: top + tail * 0.12), control: CGPoint(x: mid, y: top - tail * 0.1))
        tip.addCurve(to: CGPoint(x: mid + half + tail, y: base), control1: CGPoint(x: mid + tail * 0.55, y: top + tail * 0.35), control2: CGPoint(x: mid + half, y: base))
        tip.addLine(to: CGPoint(x: mid - half - tail, y: base + 1))
        tip.closeSubpath()
        // 合成一个轮廓：两段叠着画的话，玻璃的边光在接缝处断一下
        return path.union(tip)
    }
}
