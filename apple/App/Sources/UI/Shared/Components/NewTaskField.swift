import CueStore
import SwiftUI

/// 一行新建任务：↩ 添加，保持焦点以便连续输入。`choosesProject` 时右边可换落到哪个项目（Mac 任务页跨项目）。
/// 失焦且没写字时收回：点出来的那一行（`writing`）变回入口，`autofocus` 浮出的那一行交给 `dismiss`；写了字的留着字。Mac 上点这一行外面就算失焦（`resignsFocusOnOutsideClick`）。
struct NewTaskField: View {
    let project: UUID?
    var choosesProject = false
    /// 出现时光标就在这一行（任务页：点"新任务"后直接写）。
    var autofocus = false
    /// `autofocus` 浮出的那一行失焦且没写字时收回（任务页：收起添加那一行）。
    var dismiss: (() -> Void)?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var text = ""
    /// 点过这一行：之前只画图标与提示字，不建系统输入框——这一行常常不用，而打开任务气泡那一帧不建它少 5%～9% 的指令（实测）。
    @State private var writing = false
    @State private var chosen: UUID?
    @FocusState private var focused: Bool

    /// 落到哪个项目：换过的，没换过是给的项目，都没有（不在项目页）是默认项目。
    private var target: UUID { chosen ?? project ?? Project.defaultID }
    private let prompt = "添加任务"

    var body: some View {
        HStack(spacing: TaskMetrics.columnGap) {
            if writing || autofocus {
                glyph
                TextField(prompt, text: $text, palette: palette).textFieldStyle(.plain).font(Typography.body)
                    .submitLabel(.done)
                    .accessibilityLabel(prompt)
                    .focused($focused)
                    .onSubmit(add)
                    .onChange(of: focused) { if !focused, text.trimmingCharacters(in: .whitespaces).isEmpty { collapse() } }
                    .task {
                        // 换成输入框的那一帧还没进窗口的响应链：下一帧再接键盘
                        await NextFrame.wait()
                        focused = true
                    }
            } else {
                Button {
                    releaseKeyboard()
                    writing = true
                } label: {
                    HStack(spacing: TaskMetrics.columnGap) {
                        glyph
                        Text(prompt).font(Typography.body).foregroundStyle(palette.ink3).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(prompt)
            }
            #if os(macOS)
            if choosesProject, let projects = workspace.catalog?.projects {
                Menu {
                    ForEach(projects) { item in Button(item.name) { chosen = item.id } }
                } label: {
                    let current = projects.first { $0.id == target }
                    HStack(spacing: 4) {
                        ProjectGlyph(project: current, size: 10)
                        Text(current?.name ?? "").lineLimit(1)
                    }
                    .font(Typography.meta).foregroundStyle(palette.ink2)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(palette.fill, in: .capsule)
                    .contentShape(.capsule)
                    .menuLabel("挂到 \(current?.name ?? "")")
                }
                .menuStyle(.button).buttonStyle(PressStyle()).menuIndicator(.hidden).fixedSize()
            }
            #endif
        }
        .frame(minHeight: TaskMetrics.rowHeight)
        #if os(macOS)
        .resignsFocusOnOutsideClick()
        #endif
    }

    private func collapse() {
        if let dismiss { dismiss() } else { writing = false }
    }

    // 入口不用系统占位灰：那样看起来像不能点
    private var glyph: some View {
        Image(.add).font(Self.glyph).foregroundStyle(palette.ink2).accessibilityHidden(true)
            .frame(width: TaskMetrics.ringColumn)
    }

    #if os(macOS)
    private static let glyph = Font.system(size: 12, weight: .semibold)
    #else
    private static let glyph = Font.footnote.weight(.semibold)
    #endif

    private func add() {
        let content = text.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }
        text = ""
        let project = target
        workspace.attempt { _ = try await workspace.createTask(content, in: project) }
    }
}

/// 点了才换成输入框的那一下先让窗口交出键盘：别的输入框（Mac 的"随手记"是 AppKit 文字区）还拿着键盘时，
/// SwiftUI 接不过来，焦点停在窗口上、打的字没处去（真实点按实测）。
private func releaseKeyboard() {
    #if os(macOS)
    NSApp.keyWindow?.makeFirstResponder(nil)
    #endif
}
