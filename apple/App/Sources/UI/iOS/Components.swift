#if os(iOS)
import CueStore
import SwiftUI
import UIKit

/// 列表行的按下反馈：铺一层底色（整卡用共用的 `PressStyle(.card)`）。按下即出现，松开 160ms 淡去。
struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowPress(configuration: configuration)
    }

    /// 一行的按下反馈：底亮一层（不缩放，一屏几十行缩放会让列表显得软），按下即亮、松开慢慢退。
    private struct RowPress: View {
        let configuration: Configuration
        @Environment(\.palette) private var palette

        var body: some View {
            configuration.label
                .background { palette.fill.opacity(configuration.isPressed ? 1 : 0) }
                .animation(configuration.isPressed ? nil : Motion.quick, value: configuration.isPressed)
        }
    }
}

extension View {
    /// 列表与表单铺在桌面色上，与书架、项目页同一底色。
    func deskBackground() -> some View { modifier(DeskBackground()) }

    /// 主按钮与空态、引导共用控件外形和按压。
    func prominentButton() -> some View { buttonStyle(ControlButtonStyle(kind: .primary)) }

    /// 长按项目（书架、侧栏）：抬起这一项作预览，菜单是共用的项目操作，有 Pi 会话时菜单标题写明它的状态
    /// （说清旁边那个点是什么意思）。nil（未分类）没有菜单。
    func projectActions(_ project: Project?, radius: CGFloat, pi: PiShown?) -> some View {
        modifier(ProjectContextMenu(project: project, radius: radius, pi: pi))
    }
}

private struct ProjectContextMenu: ViewModifier {
    let project: Project?
    let radius: CGFloat
    let pi: PiShown?
    @Environment(Navigation.self) private var navigation

    func body(content: Content) -> some View {
        if let project {
            content
                .contentShape(.contextMenuPreview, .rect(cornerRadius: radius, style: .continuous))
                .contextMenu {
                    let actions = ProjectActions(project: project) { navigation.projectForm = .init(project: project) }
                    if let pi { Section(pi.presence) { actions } } else { actions }
                }
        } else {
            content
        }
    }
}

private struct DeskBackground: ViewModifier {
    @Environment(\.palette) private var palette
    func body(content: Content) -> some View { content.scrollContentBackground(.hidden).background(palette.desk) }
}

#endif
