import CueStore
import SwiftUI

nonisolated struct CueBrief: Equatable, Sendable {
    struct Line: Equatable, Identifiable, Sendable {
        enum Go: Equatable, Sendable {
            case session(String)
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

struct CueBriefBubble: View {
    let beat: CueBeat
    let status: String
    let lines: [CueBrief.Line]
    let row: CGFloat
    let open: (CueBrief.Line) -> Void
    @Environment(\.palette) private var palette

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
