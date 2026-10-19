import CueStore
import CueSync
import CueText
import SwiftUI

extension AnyTransition {
    /// 对话里一条出现或消失：只淡入淡出，动画随过渡自带。不给整段对话挂动画：其余各行的位移若也跟着动画，
    /// 底部锚定下正在读的那段会先被推走再滑回来
    static let entry = AnyTransition.opacity.animation(Motion.quick)

    /// 同一处先后换两句字（状态的一句、发送中与已送达）：旧的先淡掉、新的随后淡入——长短不同的两句同时交叉淡，中间几帧叠成读不出的一团。
    static let handOff = AnyTransition.asymmetric(
        insertion: .opacity.animation(Motion.quick.delay(Motion.handOff)), removal: .opacity.animation(.easeOut(duration: Motion.handOff)))
}


/// 你的话那颗气泡长什么样，两处各一种，只在这里分：
/// - 会话页（`session`）：四角同圆的一颗，新到的淡入。会话页是 Agent 干活的记录，回答全宽、不成泡，你的话只标出哪句是你说的，不画两边对说的样子。
/// - Cue 页（`cue`）：两边对说的对话气泡，说话那一边下角收成小角、连着说的收成一串、从右下角长出来（`CueBubble`）。
enum BubbleLook: Equatable {
    case session
    /// `joined`：上面紧挨着你的另一句。
    case cue(joined: Bool)

    private static let sessionRadius: CGFloat = 20

    var shape: UnevenRoundedRectangle {
        switch self {
        case .session: UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
            topLeading: Self.sessionRadius, bottomLeading: Self.sessionRadius, bottomTrailing: Self.sessionRadius, topTrailing: Self.sessionRadius),
            style: .continuous)
        case .cue(let joined): CueBubble.shape(.trailing, joined: joined)
        }
    }

    var padding: EdgeInsets {
        switch self {
        case .session: EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)
        case .cue: CueBubble.padding
        }
    }

    /// 气泡下那一行（发送中、已送达、没能送达）离气泡多远、离右缘多远：Cue 页的旁注对着气泡里的字（`CueBubble.noteInset`）。
    var statusSpacing: CGFloat { self == .session ? 6 : 2 }
    var statusInset: CGFloat { self == .session ? 0 : CueBubble.noteInset }

    func arrival(reduceMotion: Bool) -> AnyTransition {
        switch self {
        case .session: .entry
        case .cue: CueBubble.arrival(.trailing, reduceMotion: reduceMotion)
        }
    }
}


/// 你的一句话：右侧气泡（样子见 `BubbleLook`），最宽到所在一栏的 `widthFraction`；还在路上的整颗变淡。长按（Mac 右键）是 `menu`，预览就是这颗气泡。
/// `stored` 是存储格式正文（`CueFormat`）：文字在气泡里，带的图片是气泡下面的缩略图（`ChatImages`）；送达前后同一个样子。
struct UserBubble<Menu: View>: View {
    /// 长的话折到这么多行，点"展开"看全：会话页的重点是回答，你自己写的长提示词不该是整屏最重的一块。
    static var foldedLines: Int { 6 }
    static var widthFraction: CGFloat { 0.78 }

    let stored: String
    let look: BubbleLook
    var trip = BubbleTrip.arrived
    var highlighted = false
    /// Cue 发进会话的话：气泡上面一行 Cue 的小头像与名字（`CueByline`）。
    var fromCue = false
    @ViewBuilder var menu: Menu
    @State private var expanded = false
    /// 折起时文字确实被截掉了（按同一宽度量全文的高度比较）。
    @State private var truncated = false

    var body: some View {
        let text = CueFormat.plainText(stored), images = CueFormat.imageHashes(in: stored)
        BubbleWidth(fraction: Self.widthFraction, edge: .trailing) {
            VStack(alignment: .trailing, spacing: 6) {
                if fromCue { CueByline() }
                if !text.isEmpty || images.isEmpty {
                    BubbleText(
                        text: text, look: look, highlighted: highlighted, trip: trip, lineLimit: expanded ? nil : Self.foldedLines,
                        truncated: $truncated, expand: truncated && !expanded ? { expanded = true } : nil)
                }
                if !images.isEmpty { ChatImages(hashes: images, trip: trip) }
            }
            #if os(iOS)
            .contentShape(.contextMenuPreview, look.shape)
            #endif
            .contextMenu { menu }
        }
        .transition(.entry)
    }
}

extension UserBubble where Menu == EmptyView {
    /// 没有长按菜单的气泡（会话近况里的上一句）。
    init(stored: String) {
        self.init(stored: stored, look: .session) { EmptyView() }
    }
}


/// 气泡本身（颜色是 `Palette.bubble`）。Mac 上可以直接拖选文字。
struct BubbleText: View {
    let text: String
    let look: BubbleLook
    var highlighted = false
    var trip = BubbleTrip.arrived
    var lineLimit: Int?
    /// 给了时报告文字是否被 `lineLimit` 截掉。
    var truncated: Binding<Bool>?
    /// 折起着时：最后一行末尾渐隐，接着是"展开"（在气泡里，就在被截断的地方）。
    var expand: (() -> Void)?
    @Environment(\.palette) private var palette

    var body: some View {
        let shape = look.shape
        HStack(alignment: .center, spacing: 8) {
            if trip == .failed {
                PiStateGlyph.undelivered.accessibilityHidden(false).accessibilityLabel("没能送达")
            }
            Paragraphs(verbatim: text, lineLimit: lineLimit)
                .font(Typography.reading).foregroundStyle(palette.ink)
                .background(alignment: .topLeading) { if let truncated, mayTruncate { fullHeight(truncated) } }
                .overlay(alignment: .bottomTrailing) { if let expand { expandButton(expand) } }
                .padding(look.padding)
                .background(palette.bubble, in: shape)
                .overlay { edge(shape) }
                // 在路上：整颗淡一些，还没落进对话；送达那一刻显出实色（下面一行写着发送中，钮上是话在路上）。
                // 淡到字仍够 4.5:1（浅色 5.4、深色 6.0）：没网时它会停很久，要读得清
                .opacity(trip == .inTransit ? 0.7 : 1)
        }
        .animation(Motion.quick, value: highlighted)
        .animation(Motion.quick, value: trip)
    }

    /// 折起着、而且长到可能被截：每个气泡多挂一份量全文高的视图（每个几何读数都是一次布局回调），所以短的话（绝大多数）不挂。
    /// 一行至少放得下 40 个字节（窄到手机上的气泡，拉丁字母约 7pt 宽、汉字三字节），没到 `lineLimit` 行的字节数、又没有那么多换行的话排不满。
    private var mayTruncate: Bool {
        guard let lineLimit else { return false }
        return text.utf8.count > 40 * lineLimit || text.utf8.lazy.filter { $0 == 10 }.count >= lineLimit
    }

    private func expandButton(_ expand: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [palette.bubble.opacity(0), palette.bubble], startPoint: .leading, endPoint: .trailing).frame(width: 36)
            Button("展开", action: expand)
                .font(Typography.reading.weight(.semibold)).foregroundStyle(palette.ink2)
                .buttonStyle(.plain)
                .padding(.leading, 4)
                .background(palette.bubble)
        }
        .fixedSize()
    }

    /// 同一宽度下排全文要多高，与折起后的高度比，量出有没有被截掉；只读几何、不影响自己的排版（藏起的全文不占位）。
    private func fullHeight(_ truncated: Binding<Bool>) -> some View {
        GeometryReader { shown in
            let folded = shown.size.height
            Paragraphs(verbatim: text).font(Typography.reading).fixedSize(horizontal: false, vertical: true)
                .frame(width: shown.size.width, alignment: .leading)
                .hidden()
                .onGeometryChange(for: Bool.self) { $0.size.height > folded + 1 } action: { truncated.wrappedValue = $0 }
        }
    }

    @ViewBuilder private func edge(_ shape: UnevenRoundedRectangle) -> some View {
        switch trip {
        case .failed: shape.strokeBorder(palette.failure, lineWidth: 1)
        case .arrived, .inTransit:
            if highlighted { shape.strokeBorder(palette.signature, lineWidth: 2) } else if let edge = palette.bubbleEdge { shape.strokeBorder(edge) }
        }
    }
}


/// 你的话到哪了：进了对话、还在路上、没能送达。
enum BubbleTrip { case arrived, inTransit, failed }


/// 一条消息的长按菜单（Mac 右键）：有哪几项、什么顺序只在 `MessageMenu`，这里只画。存为灵感进会话所属的项目；
/// 编辑后重发放回这个会话的回复框（文字进输入框、图片进图片条），已经写了字就接在后面。只属于某一行的动作（选择文本、重发、移除）由那一行给。
/// `text`：你的话是存储格式正文（复制与存为灵感连图片一起；分享只给文字），Pi 与 Cue 的回答是 Markdown。
/// `session`：会话里的消息才有（存为灵感、编辑后重发要它）；Cue 页的菜单（`.cue`）没有这两项。
struct MessageActions: View {
    let text: String
    let kind: MessageMenu.Kind
    var session: PiSessionState?
    var selectText: (() -> Void)?
    var resend: (() -> Void)?
    var remove: (() -> Void)?
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let sections = MessageMenu.sections(for: kind)
        ForEach(sections.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(sections[index], id: \.self, content: item)
        }
    }

    @ViewBuilder private func item(_ item: MessageMenu.Item) -> some View {
        switch item {
        case .copy: Button(item.title, icon: item.icon) { workspace.copy(text) }
        case .selectText: if let selectText { Button(item.title, icon: item.icon, action: selectText) }
        case .share: ShareLink(item: kind == .reply ? text : CueFormat.plainText(text)) { Label(item.title, icon: item.icon) }
        case .saveAsIdea:
            if let session {
                Button(item.title, icon: item.icon) {
                    let text = text
                    workspace.attempt { try await workspace.saveReply(text, of: session) }
                }
            }
        case .editAgain: if let session { Button(item.title, icon: item.icon) { editAgain(session) } }
        case .resend:
            if let resend { Button(item.title, icon: item.icon, action: resend).disabled(!workspace.services.reachesPiHost) }
        case .remove: if let remove { Button(item.title, icon: item.icon, role: .destructive, action: remove) }
        }
    }

    /// 草稿只有一份（`AppSettings.replyDraft`）：已经写了字就接在后面，不覆盖。
    private func editAgain(_ session: PiSessionState) {
        let settings = workspace.services.settings
        var draft = settings.replyDraft(for: session.id)
        draft.append(stored: text, files: workspace.services.store.files)
        settings.setReplyDraft(draft, for: session.id)
    }
}


/// 你说出去的一句（会话页末尾还没进对话的话、Cue 页里你的话）：全 App 只此一个，状态只从记录推出（`Speech`）。
/// 发送中整颗变淡、下面转圈；已送达下面写"已送达"（`showsDelivered` 时）；没能送达写原因，给"重发"与"移除"（长按菜单里也有）。
/// 到点翻成没能送达靠全 App 一份的此刻（`AppServices.speech`）；超时后回执来了，记录一变就是已送达。
struct SpeechBubble<Menu: View>: View {
    let said: Said
    /// 重发时撤回了旧的却写不进新的：原文放回这个去处的输入框。
    let box: Binding<ComposerDraft>
    /// 已送达写不写：会话页每句都写（进了对话就不在这里），Cue 页只写你最后一句（旧的不写，免得满屏）。
    var showsDelivered = true
    /// 还在路上时的说法（会话：排队中、送达中、正在唤醒，`PiDelivery.Transit`）；nil 是"发送中"。
    var transit: PiDelivery.Transit?
    var fromCue = false
    let look: BubbleLook
    /// 长按菜单（消息菜单）；给的是此刻到哪了。
    @ViewBuilder var menu: (Speech.Trip) -> Menu
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 刚从刻度滑条跳到的那一句（Cue 页里你的话）描一圈。
    @Environment(\.chatHighlight) private var highlight

    var body: some View {
        let trip = said.trip(at: services.speech)
        VStack(alignment: .trailing, spacing: look.statusSpacing) {
            UserBubble(stored: said.content, look: look, trip: trip.bubble, highlighted: highlight == said.id, fromCue: fromCue) { menu(trip) }
            // 与气泡显出实色同一拍换字（发送中 → 已送达，`handOff`）
            status(trip).font(Typography.caption).padding(.trailing, look.statusInset)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .transition(look.arrival(reduceMotion: reduceMotion))
    }

    @ViewBuilder private func status(_ trip: Speech.Trip) -> some View {
        switch trip {
        case .sending:
            NoteLine { Spinner(.mini) } label: { Text(transit?.label ?? "发送中") }
                .accessibilityElement(children: .combine)
                .transition(.handOff)
        case .delivered:
            if showsDelivered {
                NoteLine(icon: .delivered) { Text(Dotted("已送达", said.roundTrip.map { PiClock.duration(Double($0.components.seconds)) })) }
                    .accessibilityElement(children: .combine)
                    .transition(.handOff)
            }
        case .failed(let failure):
            HStack(spacing: 10) {
                Text(failure.text(sync: services.syncStatus)).foregroundStyle(palette.failure).lineLimit(2)
                Button("移除", role: .destructive, action: remove)
                    .foregroundStyle(palette.ink2).buttonStyle(.plain)
                    .frame(minHeight: 44).contentShape(.rect)
                // 送不到 Mac 时也露出来（停用），看得出能重发
                Button("重发", icon: .retry, action: resend)
                    .font(Typography.caption.weight(.semibold)).foregroundStyle(palette.failure)
                    .padding(.horizontal, 10).frame(minHeight: 28)
                    .overlay(Capsule().strokeBorder(palette.failure, lineWidth: 1))
                    .frame(minHeight: 44).contentShape(.rect)
                    .buttonStyle(.plain)
                    .disabled(!services.reachesPiHost)
            }
        }
    }

    private func resend() { workspace.resend(said, restoringInto: box) }
    private func remove() { workspace.remove(said) }
}


extension Speech.Trip {
    var bubble: BubbleTrip {
        switch self {
        case .sending: .inTransit
        case .delivered: .arrived
        case .failed: .failed
        }
    }
}

nonisolated extension Speech.Failure {
    /// 没能送达的原因：Mac 写回的原文；超时的只分本机同步不通与 Mac 一直没收下（只说这句话，不猜 Mac 在不在：那台 Mac 在不在线看它的在线记录）。
    /// 同步不通写同步状态那套说法（`sync` 此刻的状态），手里没有同步状态的规则（项目"此刻"）只写"同步不通"——那时同步状态另有提示。
    func text(sync: SyncStatus?) -> String {
        switch self {
        case .reported(let reason): reason
        case .offline: "\(sync.map { SyncSummary($0).title } ?? "同步不通")，发不到 Mac"
        case .timedOut: "Mac 迟迟没收下这句"
        }
    }
}
