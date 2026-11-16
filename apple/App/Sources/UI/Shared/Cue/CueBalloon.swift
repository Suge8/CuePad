import CueStore
import SwiftUI

/// Cue 说的那一件：一块玻璃气泡，尾巴朝上指着云上的 Cue（浮在天空上的表面用系统玻璃，字压在花的云上时玻璃垫着底才读得清）。
/// 从上到下：来由一行（图标着状态色：出错玫红、新回复与做完绿、等子代理靛蓝；回你的是哪句时写那句），它说的那一句（大字），正文（至多四行），去处。
/// 整块是一颗钮，只去一处：新回复与做完没看的去那个会话（看过它就下台），建议各行自己是钮，其余回到对话（停在第一条新消息）。去处写在最后一行，字说去哪，箭头说点得动。
/// 否决过：去处做成气泡下面另一排玻璃胶囊（两种表面叠在天空上，散；"接着聊"与"看对话"是同一件事），小字眉题加大字直接压在云上（来由像链接，字被云吃掉）。
/// 换了一件是另一份（按 `focus` 给身份），读会话的订阅跟着换。
struct CueBalloon: View {
    let focus: CueStage.Focus
    let close: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var look: Look?

    /// 尾巴的高：气泡的框连尾巴一起算，尖顶在框的上沿。
    static let tail: CGFloat = 14
    /// 比对话的读宽窄：宽屏上一句话铺满读宽，气泡成了一条横幅，不像谁说出来的。
    static let width: CGFloat = 480
    private static let lines = 4
    private static let shot: CGFloat = 72

    var body: some View {
        let speech = speech
        Group {
            if case .invite(let invites) = focus {
                // 建议各是一颗钮（点了做那件、× 是今天先不做），整块不再是一颗钮：钮里不套钮
                VStack(alignment: .leading, spacing: Spacing.item) {
                    face(speech)
                    VStack(spacing: 0) {
                        ForEach(invites) { CueInviteRow(invite: $0, close: close).transition(.opacity) }
                    }
                    .padding(.horizontal, -Spacing.item)
                    .animation(Motion.fade, value: invites)
                    Button(action: close) { go(speech) }.buttonStyle(PressStyle()).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .modifier(Paper())
            } else {
                Button(action: act) {
                    VStack(alignment: .leading, spacing: Spacing.item) {
                        face(speech)
                        if let shot = look?.shot {
                            // 只给人认出是哪一张：点它与点气泡一样打开那件任务，成果在那里看全
                            DeliverableTile(preview: shot.preview, label: shot.look, shape: .strip(height: Self.shot), captioned: false,
                                            zoom: PreviewZoomKey(group: "stage", preview: shot.id)) { _ in }
                                .allowsHitTesting(false)
                                .padding(.top, Spacing.tight)
                        }
                        go(speech).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .modifier(Paper())
                }
                .buttonStyle(PressStyle(.card))
            }
        }
        .observing(services.store, id: key, into: $look, onError: workspace.fail) { [focus] in try Look.read(focus, from: $0) }
        .id(key)
    }

    /// 气泡的身份：换了一件是另一个气泡；建议划掉一件还是同一个，行原地淡出。
    private var key: CueStage.Focus {
        if case .invite = focus { .invite([]) } else { focus }
    }

    @ViewBuilder private func face(_ speech: Speech) -> some View {
                if let lead = speech.lead {
                    HStack(spacing: Spacing.glyph) {
                        Image(lead.icon).foregroundStyle(lead.tint)
                        Text(verbatim: lead.text).foregroundStyle(palette.ink3).lineLimit(1)
                    }
                    .font(Typography.secondary)
                }
                Text(verbatim: speech.head).font(Typography.heading).foregroundStyle(palette.ink).lineLimit(3)
                if !speech.body.isEmpty {
                    Text(verbatim: speech.body).font(Typography.body).foregroundStyle(palette.ink2).lineLimit(Self.lines)
                }
    }

    private func go(_ speech: Speech) -> some View {
        HStack(spacing: Spacing.tight) {
            Text(speech.go)
            Chevron(.forward)
        }
        .font(Typography.secondary.weight(.medium)).foregroundStyle(palette.ink2)
    }

    /// 气泡的那块玻璃：尾巴的高算在框里，字从尾巴下面排起。
    private struct Paper: ViewModifier {
        func body(content: Content) -> some View {
            content
                .multilineTextAlignment(.leading)
                .padding(.horizontal, Spacing.block)
                .padding(.top, Spacing.block + CueBalloon.tail).padding(.bottom, Spacing.group)
                .glass(in: SpeechShape(tail: CueBalloon.tail), interactive: true)
                .contentShape(SpeechShape(tail: CueBalloon.tail))
        }
    }

    /// 气泡要另读的：会话最后说的那段（新回复、做完没看的），做完的那件的成果图（同看板已完成列取的那张）。
    nonisolated private struct Look: Equatable, Sendable {
        var reply = ""
        var shot: CueShown?

        static func read(_ focus: CueStage.Focus, from store: isolated CueStore) throws -> Look {
            switch focus {
            case .reply(let item):
                return Look(reply: try store.sessionState(CueBalloon.session(of: item))?.lastReply ?? "")
            case .done(let done):
                let reply = try store.sessionState(done.session)?.lastReply ?? ""
                guard let task = try store.card(done.task), let shot = try store.cueResultShots(of: [task])[done.task]?.first,
                      let preview = try store.previews([shot.preview])[shot.preview]
                else { return Look(reply: reply) }
                return Look(reply: reply, shot: CueShown(preview: preview, look: shot.look))
            default:
                return Look()
            }
        }
    }

    private struct Speech {
        var lead: (icon: Icon, tint: Color, text: String)?
        var head: String
        var body = ""
        var go: LocalizedStringKey = "看对话"
    }

    /// 拍板、歇着、不在只有那一句：拍板是哪件、问什么在下面的拍板卡上，这里只说有几件。
    private var speech: Speech {
        switch focus {
        case .away(let reason, let failed):
            return Speech(lead: failed ? (.failure, palette.failure, String(localized: "出错了")) : nil, head: reason)
        case .asks(let count):
            return Speech(head: String(localized: "有 \(count) 件等你拍板"))
        case .reply(let item):
            let (head, body) = CueStage.Said.split(look?.reply ?? "")
            return Speech(lead: (.replied, item.kind.tone.color(palette), item.name), head: head.isEmpty ? item.kind.label : head, body: body, go: "去会话里看")
        case .said(let said):
            return Speech(lead: said.asked.map { (.reply, palette.ink3, $0) }, head: said.head, body: said.rest)
        case .done(let done):
            let (head, rest) = CueStage.Said.split(look?.reply ?? "")
            return Speech(
                lead: (.done, CueNow.Tone.done.color(palette), CueNow.Item.Kind.done.label), head: done.title,
                body: [head, rest].filter { !$0.isEmpty }.joined(separator: "\n"), go: "看结果")
        case .delegating(let item):
            return Speech(lead: (.relay, item.kind.tone.color(palette), item.kind.label), head: item.name)
        case .invite:
            return Speech(head: String(localized: "这几件，要不要顺手做了？"))
        case .quiet(let line):
            return Speech(head: line)
        }
    }

    /// 待回复的 id 是 "reply/会话 id"（`CueTally.Reply.id`）。
    nonisolated static func session(of item: CueNow.Item) -> String { String(item.id.dropFirst("reply/".count)) }

    private func act() {
        close()
        switch focus {
        case .reply(let item):
            let session = Self.session(of: item)
            workspace.openSession(SessionState.recordID(sessionID: session), sessionID: session)
        case .done(let done):
            workspace.openSession(SessionState.recordID(sessionID: done.session), sessionID: done.session)
        default: break
        }
    }
}

/// 气泡的形：圆角的身子，上沿正中一个小尖朝上。尖的两肩与顶都是圆的，同系统气泡的尾巴：直角的三角像贴上去的。
nonisolated private struct SpeechShape: Shape {
    let tail: CGFloat

    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY + tail, width: rect.width, height: rect.height - tail)
        let path = Path(roundedRect: body, cornerRadius: Radius.sheet, style: .continuous)
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
