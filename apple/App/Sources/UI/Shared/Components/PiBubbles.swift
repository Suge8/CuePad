import CueStore
import CueText
import SwiftUI

extension AnyTransition {
    /// 对话里一条出现或消失：只淡入淡出，动画随过渡自带。不给整段对话挂动画：其余各行的位移若也跟着动画，
    /// 底部锚定下正在读的那段会先被推走再滑回来
    static let entry = AnyTransition.opacity.animation(Motion.quick)
}


/// 你的一句话：右侧气泡，最宽到所在一栏的四分之三；还在路上的整颗变淡。长按（Mac 右键）是 `menu`，预览就是这颗气泡。
/// `stored` 是存储格式正文（`CueFormat`）：文字在气泡里，带的图片是气泡下面的缩略图（`ChatImages`）；送达前后同一个样子。
struct UserBubble<Menu: View>: View {
    private static var widthFraction: CGFloat { 0.78 }

    /// 长的话折到这么多行，点"展开"看全：会话页的重点是回答，你自己写的长提示词不该是整屏最重的一块。
    private static var foldedLines: Int { 6 }

    let stored: String
    var trip = BubbleTrip.arrived
    var highlighted = false
    @ViewBuilder var menu: Menu
    @State private var expanded = false
    /// 折起时文字确实被截掉了（按同一宽度量全文的高度比较）。
    @State private var truncated = false

    var body: some View {
        let text = CueFormat.plainText(stored), images = CueFormat.imageHashes(in: stored)
        TrailingFraction(fraction: Self.widthFraction) {
            VStack(alignment: .trailing, spacing: 6) {
                if !text.isEmpty || images.isEmpty {
                    BubbleText(
                        text: Dotted(text), highlighted: highlighted, trip: trip, lineLimit: expanded ? nil : Self.foldedLines,
                        truncated: $truncated, expand: truncated && !expanded ? { expanded = true } : nil)
                }
                if !images.isEmpty { ChatImages(hashes: images, trip: trip) }
            }
            #if os(iOS)
            .contentShape(.contextMenuPreview, BubbleText.shape)
            #endif
            .contextMenu { menu }
        }
        .transition(.entry)
    }
}

extension UserBubble where Menu == EmptyView {
    /// 没有长按菜单的气泡（近况里的上一句）。
    init(stored: String, trip: BubbleTrip = .arrived, highlighted: Bool = false) {
        self.init(stored: stored, trip: trip, highlighted: highlighted) { EmptyView() }
    }
}


/// 气泡本身（颜色是 `Palette.bubble`）。Mac 上可以直接拖选文字。
struct BubbleText: View {
    static let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    let text: Dotted
    var highlighted = false
    var trip = BubbleTrip.arrived
    var lineLimit: Int?
    /// 给了时报告文字是否被 `lineLimit` 截掉。
    var truncated: Binding<Bool>?
    /// 折起着时：最后一行末尾渐隐，接着是"展开"（在气泡里，就在被截断的地方）。
    var expand: (() -> Void)?
    @Environment(\.palette) private var palette

    var body: some View {
        let shape = Self.shape
        HStack(alignment: .center, spacing: 8) {
            if trip == .failed {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(palette.failure).accessibilityLabel("没能送达")
            }
            Text(text)
                .font(Typography.reading).foregroundStyle(palette.ink)
                .lineLimit(lineLimit)
                .selectable()
                .background(alignment: .topLeading) { if let truncated, mayTruncate { fullHeight(truncated) } }
                .overlay(alignment: .bottomTrailing) { if let expand { expandButton(expand) } }
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(palette.bubble, in: shape)
                .overlay { edge(shape) }
                // 在路上：半透明加虚线边，浅色深色一样看得出还没到
                .opacity(trip == .inTransit ? 0.6 : 1)
        }
        .animation(Motion.quick, value: highlighted)
        .animation(Motion.quick, value: trip)
    }

    /// 折起着、而且长到可能被截：每个气泡多挂一份量全文高的视图（每个几何读数都是一次布局回调），所以短的话（绝大多数）不挂。
    /// 一行至少放得下 40 个字节（窄到手机上的气泡，拉丁字母约 7pt 宽、汉字三字节），没到 `lineLimit` 行的字节数、又没有那么多换行的话排不满。
    private var mayTruncate: Bool {
        guard let lineLimit else { return false }
        let visible = text.visible
        return visible.utf8.count > 40 * lineLimit || visible.utf8.lazy.filter { $0 == 10 }.count >= lineLimit
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
            Text(text).font(Typography.reading).fixedSize(horizontal: false, vertical: true)
                .frame(width: shown.size.width, alignment: .leading)
                .hidden()
                .onGeometryChange(for: Bool.self) { $0.size.height > folded + 1 } action: { truncated.wrappedValue = $0 }
        }
    }

    @ViewBuilder private func edge(_ shape: RoundedRectangle) -> some View {
        switch trip {
        case .inTransit: shape.strokeBorder(palette.ink2, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        case .failed: shape.strokeBorder(palette.failure, lineWidth: 1)
        case .arrived: shape.strokeBorder(highlighted ? palette.signature : palette.bubbleEdge, lineWidth: highlighted ? 2 : 1)
        }
    }
}


/// 你的话到哪了：进了对话、还在路上、没能送达。
enum BubbleTrip { case arrived, inTransit, failed }


/// 一条消息的长按菜单（Mac 右键）：有哪几项、什么顺序只在 `MessageMenu`，这里只画。存为灵感进会话所属的项目；
/// 编辑后重发放回这个会话的回复框（文字进输入框、图片进图片条），已经写了字就接在后面。只属于某一行的动作（选择文本、重发、移除）由那一行给。
/// `text`：你的话是存储格式正文（复制与存为灵感连图片一起；分享只给文字），Pi 的回答是 Markdown。
struct MessageActions: View {
    let text: String
    let kind: MessageMenu.Kind
    let session: PiSessionState
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
        case .copy: Button(item.title, systemImage: item.symbol) { workspace.copy(text) }
        case .selectText: if let selectText { Button(item.title, systemImage: item.symbol, action: selectText) }
        case .share: ShareLink(item: kind == .reply ? text : CueFormat.plainText(text)) { Label(item.title, systemImage: item.symbol) }
        case .saveAsIdea:
            Button(item.title, systemImage: item.symbol) {
                let text = text, session = session
                workspace.attempt { try await workspace.saveReply(text, of: session) }
            }
        case .editAgain: Button(item.title, systemImage: item.symbol, action: editAgain)
        case .resend:
            if let resend { Button(item.title, systemImage: item.symbol, action: resend).disabled(!workspace.services.reachesPiHost) }
        case .remove: if let remove { Button(item.title, systemImage: item.symbol, role: .destructive, action: remove) }
        }
    }

    /// 草稿只有一份（`AppSettings.replyDraft`）：已经写了字就接在后面，不覆盖。
    private func editAgain() {
        let settings = workspace.services.settings
        var draft = settings.replyDraft(for: session.id)
        draft.append(stored: text, files: workspace.services.store.files)
        settings.setReplyDraft(draft, for: session.id)
    }
}


/// 你发出、还没进对话的话：你的气泡，下面送达情况；没能送达时写原因，可以重发或移除。
struct OutgoingBubble: View {
    let request: DeliveryRequest
    let session: PiSessionState
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    private var failed: Bool { request.status == .known(.failed) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            UserBubble(stored: request.content, trip: failed ? .failed : request.isOpen ? .inTransit : .arrived) {
                MessageActions(text: request.content, kind: .outgoing(failed: failed), session: session, resend: retry, remove: remove)
            }
            HStack(spacing: 10) {
                if failed {
                    if let reason = request.failure { Text(reason).font(Typography.caption).foregroundStyle(palette.failure).lineLimit(2) }
                    // 送不到 Mac 时也露出来（停用），看得出能重发
                    Button("重发", systemImage: "arrow.clockwise", action: retry)
                        .font(Typography.caption.weight(.semibold)).foregroundStyle(palette.failure)
                        .padding(.horizontal, 10).frame(minHeight: 28)
                        .overlay(Capsule().strokeBorder(palette.failure, lineWidth: 1))
                        .frame(minHeight: 44).contentShape(.rect)
                        .buttonStyle(.plain)
                        .disabled(!workspace.services.reachesPiHost)
                } else {
                    DeliveryStatusLabel(request: request, session: session).font(Typography.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .transition(.entry)
    }

    /// 同样的内容与方式再发一次；新请求写成后移除这条失败的。
    private func retry() {
        let old = request, session = session
        workspace.attempt {
            _ = try await workspace.services.requestMacDelivery(
                old.content, to: session, mode: old.mode.known ?? .followUp, card: old.cardID)
            try await workspace.services.store.deleteDelivery(old.id)
        }
    }

    private func remove() {
        let id = request.id
        workspace.perform { try await $0.deleteDelivery(id) }
    }
}
