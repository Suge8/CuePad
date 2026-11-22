import CueStore
import SwiftUI

struct Composer<Header: View, Tools: View, Send: View>: View {
    @Binding var draft: ComposerDraft
    let prompt: LocalizedStringResource?
    var promptIcon: Icon?
    let label: LocalizedStringResource
    let focus: FocusState<Bool>.Binding
    var accepts: ComposerKinds = [.files, .cards]
    var cardsFrom: UUID?
    var form = ComposerForm.open
    var keeps: UUID?
    var submitsEmpty = false
    var showsSendEmpty = false
    var yielded = false
    var lead: ComposerLead?
    var keepsHeader = false
    var tooled = false
    var commands: [SlashCommand] = []
    var shortcuts: [ReplyShortcut: () -> Void] = [:]
    var keys: [ComposerKey: () -> Void] = [:]
    var recall: String?
    @ViewBuilder let header: () -> Header
    @ViewBuilder let tools: () -> Tools
    @ViewBuilder let send: () -> Send
    @Environment(Workspace.self) var workspace
    @Environment(\.palette) var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.sendFlight) private var flight
    /// 跟着焦点、带动画：UIKit 文字区拿到焦点时的那次更新不带动画，直接读焦点时展开会一帧跳到位
    @State private var focused = false
    @State var source: ComposerSource?
    @State var previewing: Outbox?
    @State private var highlighted = 0
    @State private var dismissedPalette: String?
    @Namespace private var plusSlot

    private var expanded: Bool { form.expanded(focused: focused, draft: draft, accepts: accepts) }
    private var shrunk: Bool { form.isCapsule && !focused }
    private var showsTools: Bool { form == .open || focused }
    private var toolsShown: Bool { tooled && expanded && showsTools }
    var buttonHeight: CGFloat {
        toolsShown ? ComposerMetrics.slot : ComposerMetrics.lineSlot(line: ComposerField.lineHeight(typeSize))
    }
    private var shrunkDraft: String? { shrunk ? draft.preview : nil }
    private static var compactWidth: CGFloat { 220 }
    private static var headerTransition: AnyTransition {
        .asymmetric(insertion: .opacity.animation(Motion.fade.delay(Motion.Fade.settle)), removal: .identity)
    }
    private static var overhang: CGFloat { 120 }
    private var hasContent: Bool { !draft.isEmpty(accepting: accepts) }
    private var sendVisible: Bool { !shrunk && (hasContent || submitsEmpty || showsSendEmpty) }

    private var paletteCommands: [SlashCommand] {
        guard expanded, dismissedPalette != draft.text else { return [] }
        return Slash.matches(draft.text, in: commands) ?? []
    }

    private func shortcut(_ key: ReplyShortcut) -> (() -> Void)? {
        key == .send && !hasContent && !submitsEmpty ? nil : shortcuts[key]
    }

    private func handle(_ key: ComposerKey) -> Bool {
        let list = paletteCommands
        guard !list.isEmpty else {
            if let act = keys[key] {
                act()
                return true
            }
            guard key == .up, let recall, draft.isEmpty(accepting: accepts.subtracting(.notes)) else { return false }
            draft.append(stored: recall)
            return true
        }
        let current = min(highlighted, list.count - 1)
        switch key {
        case .up: highlighted = (current + list.count - 1) % list.count
        case .down: highlighted = (current + 1) % list.count
        case .accept, .next: pick(list[current])
        case .dismiss: dismissedPalette = draft.text
        case .previous: break
        }
        return true
    }

    private func pick(_ command: SlashCommand) {
        draft.text = Slash.insertion(for: command)
        focus.wrappedValue = true
    }

    var body: some View {
        field
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: shrunk)
        .onChange(of: focus.wrappedValue, initial: true) { _, now in
            // 一直展开时焦点不改形状，不起动画：Mac 会话页打开即聚焦，白跑的一段动画每帧都要 AppKit 重算整窗的跟踪区
            if form == .open { focused = now } else { withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { focused = now } }
        }
        .animation(Motion.fade, value: paletteCommands.isEmpty)
        .onChange(of: draft.text) { highlighted = 0 }
        .animation(Motion.fade, value: draft.attachments.map(\.id))
        .animation(Motion.fade, value: draft.files)
        .modifier(FileSources(source: $source) { add($0) })
        .modifier(CardPanels(on: accepts.contains(.cards), picking: $source.isOn(.cards), previewing: $previewing) {
            CardPicker(project: cardsFrom) { draft.attach($0) }
        } preview: { outbox in
            AttachmentSheet(outbox: outbox) { expand(outbox) }
        })
        .task { await DebugHooks.presetComposer($draft, source: $source, store: workspace.services.store) }
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !shrunk, expanded || keepsHeader { header().transition(Self.headerTransition) }
            if !paletteCommands.isEmpty {
                SlashPalette(commands: paletteCommands, highlighted: min(highlighted, paletteCommands.count - 1), pick: pick)
                    .transition(.opacity)
            }
            if accepts.contains(.cards) {
                ForEach(draft.attachments) { chip($0).padding([.horizontal, .top], ComposerMetrics.inset).transition(.opacity) }
            }
            if accepts.contains(.files), !draft.files.isEmpty {
                fileStrip.padding([.horizontal, .top], ComposerMetrics.inset).transition(.opacity)
            }
            rows.layoutPriority(1)
        }
        .overlay(alignment: .bottomTrailing) { if !shrunk { sendSlot } }
        .background {
            if !focused, !yielded {
                Color.clear.contentShape(.rect(cornerRadius: Radius.field))
                    .onTapGesture { focus.wrappedValue = true }
                    .readerHidden(true)
            }
        }
        .frame(maxWidth: shrunk ? Self.compactWidth : .infinity, alignment: .leading)
        .mask { RoundedRectangle(cornerRadius: Radius.field).padding(.top, -Self.overhang) }
        .rowContainer(.rect(cornerRadius: Radius.field))
        .glass(in: .rect(cornerRadius: Radius.field), interactive: !expanded)
        .frame(maxWidth: .infinity)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 0) {
                if !accepts.isEmpty, !toolsShown { plus.matchedGeometryEffect(id: 0, in: plusSlot) }
                text
                    .padding(.leading, toolsShown || accepts.isEmpty ? Spacing.block : Spacing.hair)
                    .padding(.trailing, toolsShown || shrunk ? Spacing.block : Spacing.hair)
                    .padding(.top, ComposerMetrics.textTop)
                    .padding(.bottom, toolsShown ? ComposerMetrics.textBottomOpen : ComposerMetrics.textTop)
                    .frame(minHeight: toolsShown ? nil : buttonHeight)
                    .modifier(Yield(yielded: yielded))
                if !toolsShown, !shrunk { slotSpace }
            }
            if toolsShown {
                HStack(spacing: 0) {
                    if !accepts.isEmpty { plus.matchedGeometryEffect(id: 0, in: plusSlot) }
                    tools().environment(\.chipHeight, ComposerMetrics.glyph).environment(\.bubbleInset, ComposerMetrics.glyphEdge)
                        .padding(.leading, accepts.isEmpty ? ComposerMetrics.glyphEdge : 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(Yield(yielded: yielded))
                        .transition(Motion.pop(reduceMotion: reduceMotion))
                    slotSpace
                }
            }
        }
    }

    /// 发出的那句还在飞时不出占位字：字从它上面起飞，叠着读不清；落下那一刻占位字才回来。
    private var text: some View {
        let prompt = flight?.trip == nil ? prompt : nil
        return ComposerField(
            text: $draft.text, prompt: promptIcon == nil ? prompt.map { String(localized: $0) } ?? "" : "", label: String(localized: label), maxLines: expanded ? 6 : 1, ink: palette.ink, focus: focus, keys: handle,
            shortcut: shortcut, files: accepts.contains(.files) ? { add($0) } : nil)
            .focused(focus)
            #if os(macOS)
            .padding(.horizontal, -GrowingTextView.caretRoom)
            .yieldsFocusWhenCovered(focus)
            #endif
            .sendsFlight()
            .animation(nil) { $0.opacity(shrunkDraft == nil ? 1 : 0) }
            .overlay(alignment: .leading) {
                if let shrunkDraft {
                    Text("草稿：\(shrunkDraft)").font(Typography.reading).foregroundStyle(palette.ink2).lineLimit(1)
                        .allowsHitTesting(false)
                        .transition(.identity)
                } else if let promptIcon, let prompt, draft.text.isEmpty {
                    HStack(spacing: Spacing.glyph) {
                        Image(promptIcon).readerHidden(true)
                        Text(prompt)
                    }
                    .font(Typography.reading).foregroundStyle(palette.ink3).lineLimit(1)
                    .allowsHitTesting(false)
                    .transition(.identity)
                }
            }
    }

    /// 提交钮的位置一直留着（收成短胶囊时除外）：有内容才放进来，输入框的宽度不随它变，文字不会因此重排——
    /// 宽度跟着钮进出变的话，动画的每一帧文字区（UITextView/NSTextView）都要重新排版，发出、送达、打第一个字各多一段主线程开销。
    private var slotSpace: some View { Color.clear.frame(width: ComposerMetrics.slot, height: buttonHeight) }

    private var sendSlot: some View {
        ZStack {
            if sendVisible { send().transition(Motion.pop(reduceMotion: reduceMotion)) }
        }
        .frame(width: ComposerMetrics.slot, height: buttonHeight)
        .animation(Motion.fade, value: sendVisible)
    }
}

struct ComposerLead: Equatable {
    let icon: Icon
    let label: LocalizedStringResource
    var on = false
    var enabled = true
    let act: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.icon == b.icon && a.label.key == b.label.key && a.on == b.on && a.enabled == b.enabled
    }
}

private struct Yield: ViewModifier {
    let yielded: Bool

    func body(content: Content) -> some View {
        content
            .opacity(yielded ? 0 : 1)
            .allowsHitTesting(!yielded)
            .readerHidden(yielded)
            .animation(yielded ? Motion.yield : Motion.fade.delay(Motion.Fade.yield), value: yielded)
    }
}
