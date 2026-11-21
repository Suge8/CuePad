import SwiftUI

struct NoticeSlot: View {
    let place: NoticeCapsule.Place
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let notice = workspace.noticeInRail == (place == .rail) ? workspace.notice : nil
        ZStack {
            if let notice {
                NoticeCapsule(notice: notice, place: place)
                    .transition(Motion.surface(from: place == .rail ? .bottom : .top, reduceMotion: reduceMotion))
            }
        }
        .animation(notice == nil ? Motion.fade : Motion.fading(Motion.nudge, reduceMotion: reduceMotion), value: notice)
        .onChange(of: workspace.noticeInRail) { workspace.holdNotice(false) }
    }
}

struct NoticeCapsule: View {
    enum Place: Equatable {
        case head(fills: Bool)
        case rail
    }

    let notice: Workspace.Notice
    let place: Place
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var landed = false
    @State private var armed = false
    @FocusState private var focus: Part?

    private enum Part { case link, action }

    private var held: Bool { hovering || focus != nil || voiceOver || DebugHooks.preset.readerOn }
    private var acts: Bool { notice.link != nil || notice.action != nil }

    var body: some View {
        let height = ControlSize.regular.height
        Group {
            switch place {
            case .head(let fills):
                ViewThatFits(in: .vertical) {
                    row(font: Typography.secondary, lines: 2, inset: ControlSize.regular.verticalPadding)
                    row(font: Typography.meta, lines: 2, inset: Spacing.tight)
                    row(font: Typography.secondary, lines: 1, inset: ControlSize.regular.verticalPadding)
                }
                #if os(iOS)
                .dynamicTypeSize(...FloatingHeaderLayout.largestType)
                #endif
                .frame(maxWidth: fills ? .infinity : nil)
                .frame(height: height)
            case .rail:
                row(font: Typography.secondary, lines: 4, inset: ControlSize.regular.verticalPadding).frame(minHeight: height)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .glass(in: .rect(cornerRadius: height / 2), interactive: acts)
        .elevation(.panel)
        .onHover { hovering = $0 }
        #if os(macOS)
        .presetHover($hovering)
        #endif
        .gesture(DragGesture(minimumDistance: Self.fling).onEnded { _ in workspace.notice = nil })
        .allowsHitTesting(notice.takesHits && armed)
        .task(id: notice.id) {
            armed = false
            guard (try? await Task.sleep(for: Self.arming)) != nil else { return }
            armed = true
        }
        .onChange(of: held, initial: true) { was, now in if was != now || now { workspace.holdNotice(now) } }
        .onChange(of: notice.id, initial: true) {
            if held { workspace.holdNotice(true) }
            AccessibilityNotification.Announcement(notice.text.spoken).post()
            if workspace.soundedNotice != notice.id {
                workspace.soundedNotice = notice.id
                if let sound = notice.sound { workspace.services.settings.play(sound) }
            }
            landed = false
            withAnimation(Motion.fading(Motion.nudge, reduceMotion: reduceMotion).delay(Motion.Fade.settle)) { landed = true }
        }
        .accessibilityHint(notice.link == nil ? "" : "去那里看看")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityAction(.escape) { workspace.notice = nil }
    }

    private static let fling: CGFloat = 16
    private static let arming: Duration = .milliseconds(500)

    private func row(font: Font, lines: Int, inset: CGFloat) -> some View {
        HStack(spacing: 0) {
            message(inset: inset)
            if let action = notice.action {
                Group {
                    if action.undoes != nil {
                        Button(action.title, icon: .undo) { workspace.run(action) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(ControlButtonStyle(kind: .icon, size: .compact))
                            .help(action.title)
                    } else {
                        Button(action.title) { workspace.run(action) }
                            .buttonStyle(ControlButtonStyle(kind: .quiet, size: .compact))
                    }
                }
                .focused($focus, equals: .action)
                .fixedSize()
                .padding(.trailing, Spacing.tight)
            }
        }
        .font(font.weight(.medium)).lineLimit(lines)
        .fixedSize(horizontal: false, vertical: lines > 1)
    }

    /// 没有去处时不是按钮：停用的按钮整块压淡，字只剩一半深，键盘也不该停在点了没反应的东西上。
    @ViewBuilder private func message(inset: CGFloat) -> some View {
        let label = HStack(spacing: Spacing.glyph) {
            Label { Text(notice.text).contentTransition(.opacity) } icon: {
                Group {
                    if let status = notice.status { StateGlyph(status: status) } else { Image(notice.tone.icon) }
                }
                .scaleEffect(landed || reduceMotion ? 1 : 0.6).opacity(landed ? 1 : 0)
            }
            if notice.link != nil { Chevron(.forward).foregroundStyle(palette.ink3) }
        }
        .multilineTextAlignment(.leading)
        .foregroundStyle(notice.isError ? palette.failure : palette.ink)
        .padding(.leading, ControlSize.regular.padding)
        .padding(.trailing, notice.action == nil ? ControlSize.regular.padding : Spacing.tight)
        .padding(.vertical, inset)
        .contentShape(.rect)
        if let link = notice.link {
            Button { workspace.go(to: link) } label: { label }
                .buttonStyle(PressStyle())
                .focused($focus, equals: .link)
        } else {
            label.onTapGesture { workspace.notice = nil }
        }
    }
}
