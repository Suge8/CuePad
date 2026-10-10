#if os(iOS)
import CueStore
import SwiftUI
import UIKit

/// 列表行的按下反馈：铺一层底色（整卡用共用的 `CardPressStyle`）。按下即出现，松开 160ms 淡去。
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

    /// 独占底部的页（卡片纸页、Pi 会话页）：在屏幕上时 iPhone 收起标签栏（见 `Navigation.bottomPages`）。
    func ownsBottomEdge() -> some View { modifier(BottomEdgeOwner()) }

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

private struct BottomEdgeOwner: ViewModifier {
    @Environment(Navigation.self) private var navigation
    @State private var counted = false

    func body(content: Content) -> some View {
        content.background {
            PageAppearance { visible in
                guard visible != counted else { return }
                counted = visible
                navigation.bottomPages += visible ? 1 : -1
            }
        }
    }
}

/// 页面在屏幕上（含推入、返回途中）的起止，跟 UIKit 的出现回调走：手势返回在手指开始拖时就收到"将消失"，
/// 取消返回再收到"将出现"。SwiftUI 的导航路径要到松手才变，跟它走标签栏会晚出现。
private struct PageAppearance: UIViewControllerRepresentable {
    let changed: (Bool) -> Void

    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ probe: Probe, context: Context) { probe.changed = changed }

    final class Probe: UIViewController {
        var changed: (Bool) -> Void = { _ in }
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            changed(true)
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            changed(false)
        }
    }
}

private struct DeskBackground: ViewModifier {
    @Environment(\.palette) private var palette
    func body(content: Content) -> some View { content.scrollContentBackground(.hidden).background(palette.desk) }
}

#endif
