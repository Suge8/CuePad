import CueStore
import SwiftUI

/// 项目页任务清单末尾那一行；看板上记任务是另一个输入框（`NewTaskInput`）。
struct NewTaskField: View {
    let project: UUID?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var text = ""
    /// 点过这一行：之前只画图标与提示字，不建系统输入框——这一行常常不用，而打开任务气泡那一帧不建它少 5%～9% 的指令（实测）。
    @State private var writing = false
    @FocusState private var focused: Bool

    private let prompt = String(localized: "添加任务")

    var body: some View {
        HStack(spacing: TaskMetrics.columnGap) {
            if writing {
                glyph
                field
            } else {
                Button {
                    releaseKeyboard()
                    writing = true
                } label: {
                    HStack(spacing: TaskMetrics.columnGap) {
                        glyph
                        Text(prompt).font(Typography.body).foregroundStyle(palette.ink3).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: TaskMetrics.rowHeight)
                    .contentShape(.rect)
                }
                // 整行是入口，底与任务行同一种（悬停、按下铺满这一行，不贴着那几个字）
                .buttonStyle(.row)
                .accessibilityLabel(prompt)
            }
        }
        .frame(minHeight: TaskMetrics.rowHeight)
        #if os(macOS)
        .resignsFocusOnOutsideClick()
        #endif
    }

    private var field: some View {
        TextField(prompt, text: $text, palette: palette).textFieldStyle(.plain)
            .font(Typography.body)
            .submitLabel(.done)
            .accessibilityLabel(prompt)
            .focused($focused)
            .onSubmit(add)
            .onChange(of: focused) { if !focused, text.trimmingCharacters(in: .whitespaces).isEmpty { writing = false } }
            .task {
                // 换成输入框的那一帧还没进窗口的响应链：下一帧再接键盘
                await NextFrame.wait()
                focused = true
            }
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
        let project = project ?? Project.defaultID
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
