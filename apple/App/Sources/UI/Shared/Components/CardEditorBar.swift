import CueEditor
import CueStore
import CueText
import SwiftUI

/// 自己滚动的正文编辑器左下角浮着的那一排：手机、iPad 上聚焦时的「+」，正文里有变量时的变量取值。左缘与正文的字对齐（Mac 的正文按 `maxTextWidth` 居中，跟着居中）。
/// 随内容长高的编辑器（任务气泡）没有这一排：「+」在气泡的底栏，变量的取值行直接摆在正文下面（气泡里开不了第二个气泡）。
struct CardEditorBar: View {
    let card: Card
    let editing: CardEditing
    let theme: CueEditorTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassEffectContainer(spacing: Spacing.item) {
            HStack(spacing: Spacing.item) {
                #if os(iOS)
                if inserting {
                    CardInsertMenu(editing: editing) { FloatingGlyph(icon: .add) }
                        .transition(Motion.pop(reduceMotion: reduceMotion))
                }
                #endif
                VariablesChip(card: card, editing: editing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: Self.column(theme).map { $0 + 2 * Self.bleed })
        .padding([.horizontal, .bottom], Self.margin(theme))
        .frame(maxWidth: .infinity)
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: inserting)
    }

    private var inserting: Bool {
        #if os(iOS)
        editing.handle.focused
        #else
        false
        #endif
    }

    static func clearance(_ theme: CueEditorTheme) -> CGFloat { margin(theme) + FloatingGlyph.size + Spacing.item }

    private static func margin(_ theme: CueEditorTheme) -> CGFloat { theme.horizontalInset - bleed }
    private static var bleed: CGFloat { (FloatingGlyph.size - FloatingGlyph.face) / 2 }

    private static func column(_ theme: CueEditorTheme) -> CGFloat? {
        #if os(macOS)
        theme.maxTextWidth
        #else
        nil
        #endif
    }
}

struct VariablesChip: View {
    let card: Card
    let editing: CardEditing
    @Environment(\.palette) private var palette
    @State private var open = BubbleSwitch()

    var body: some View {
        let names = CueVariables.names(in: editing.text)
        if let first = names.first {
            Button { open.toggle() } label: { face(first, more: names.count - 1) }
                .buttonStyle(PressStyle())
                .bubble($open, width: .fixed(Self.formWidth)) {
                    VariablesFields(card: card, names: names) { open.open = false }.padding(Spacing.group)
                }
                .help("变量取值")
                .accessibilityLabel("变量取值，共 \(names.count) 个")
        }
    }

    private func face(_ name: String, more: Int) -> some View {
        let value = card.variableValues[name].flatMap { $0.isEmpty ? nil : $0 }
        return HStack(spacing: Spacing.tight) {
            Text("{{\(name)}}").foregroundStyle(palette.ink)
            Text(value ?? String(localized: "未填")).foregroundStyle(value == nil ? palette.ink2 : palette.ink).lineLimit(1)
            if more > 0 { Text(verbatim: "+\(more)").foregroundStyle(palette.ink2) }
            Chevron(.expand).foregroundStyle(palette.ink2)
        }
        .font(Typography.secondary.weight(.medium))
        .padding(.horizontal, Spacing.inset)
        .frame(height: FloatingGlyph.face)
        .glass(in: .capsule, interactive: true)
        .padding((FloatingGlyph.size - FloatingGlyph.face) / 2)
        .contentShape(.capsule)
    }

    private static let formWidth: CGFloat = 300
}

struct VariablesFields: View {
    let card: Card
    let names: [String]
    var submit: (() -> Void)?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(spacing: Spacing.item) {
            ForEach(names, id: \.self) { name in
                HStack(spacing: Spacing.item) {
                    Text("{{\(name)}}").foregroundStyle(palette.ink2).lineLimit(1).fixedSize()
                    TextField(text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }), prompt: Text(verbatim: "")) { Text("{{\(name)}}") }
                        .textFieldStyle(.plain)
                        .foregroundStyle(palette.ink)
                }
                .font(Typography.body)
                .padding(.horizontal, Spacing.inset)
                .frame(height: ControlSize.regular.height)
                .background(palette.fill, in: .rect(cornerRadius: Radius.field))
            }
        }
        .onAppear { values = card.variableValues }
        .onChange(of: values) { workspace.saveVariables(values, of: card) }
        .onSubmit { submit?() }
    }
}
