import CueStore
import SwiftUI

struct NewTaskField: View {
    let project: UUID?
    var choosesProject = false
    /// 看板的列里：输入独占一行、挂到哪个项目另起一行。并排的话窄列里项目胶囊把输入挤得只剩一两个字。
    var stacked = false
    var autofocus = false
    var dismiss: (() -> Void)?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var text = ""
    /// 点过这一行：之前只画图标与提示字，不建系统输入框——这一行常常不用，而打开任务气泡那一帧不建它少 5%～9% 的指令（实测）。
    @State private var writing = false
    @State private var chosen: UUID?
    @FocusState private var focused: Bool

    private var target: UUID { chosen ?? project ?? Project.defaultID }
    private let prompt = String(localized: "添加任务")

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: Spacing.item) {
                    // 长标题在 Mac 的窄列里折行写全。iOS 上竖着长的输入框按回车不走 onSubmit，拼音还没上屏时直接丢字（模拟器实测），那边的列也宽，留单行
                    #if os(macOS)
                    field(.vertical).font(TaskMetrics.lineFont).lineLimit(1...6)
                    #else
                    field(.horizontal).font(TaskMetrics.lineFont)
                    #endif
                    destination.lineLimit(1)
                }
                .padding(.vertical, TaskMetrics.cardPadding)
            } else {
                HStack(spacing: TaskMetrics.columnGap) {
                    if writing || autofocus {
                        glyph
                        field(.horizontal).font(Typography.body)
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
                    destination
                }
                .frame(minHeight: TaskMetrics.rowHeight)
            }
        }
        #if os(macOS)
        .resignsFocusOnOutsideClick()
        #endif
    }

    private func field(_ axis: Axis) -> some View {
        TextField(prompt, text: $text, palette: palette, axis: axis).textFieldStyle(.plain)
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
    }

    @ViewBuilder private var destination: some View {
        if choosesProject, let projects = workspace.catalog?.projects { projectMenu(projects) }
    }

    private func projectMenu(_ projects: [Project]) -> some View {
        let current = projects.first { $0.id == target }
        return MenuButton(sections: [
            ChoiceMenu.Section(choices: projects.map { item in
                ChoiceMenu.Choice(title: .verbatim(item.shownName), checked: item.id == target) { chosen = item.id }
            }),
        ], accessibilityLabel: "挂到 \(current?.shownName ?? "")") {
            DestinationChip(project: current)
        }
    }

    private func collapse() {
        if let dismiss { dismiss() } else { writing = false }
    }

    // 入口不用系统占位灰：那样看起来像不能点
    private var glyph: some View {
        Image(.add).font(Glyph.small).foregroundStyle(palette.ink2).readerHidden(true)
            .frame(width: TaskMetrics.ringColumn)
    }

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
