#if os(macOS)
import SwiftUI

extension TaskPicker {
    private static let macSize = CGSize(width: 440, height: 540)
    /// 列表在面板下沿淡出的那一段。
    private static let bottomFade: CGFloat = 20

    /// Mac 与手机同一种质感：标题居中、右上一颗关闭钮（与手机同一个叉，Esc 也关），搜索占满一行，"新建任务…"单独一张纸，
    /// 每个项目一张纸、行间不画线；列表滚到面板下沿时在最后一段淡出，不被下沿硬切。
    var content: some View {
        VStack(spacing: 14) {
            PanelHeader("挂到任务")
            PanelSearchField(prompt: "搜索任务", text: $text)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    newTask.font(Typography.body).padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .paper(radius: 12)
                    ForEach(shown, id: \.projectID) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            header(group.projectID).font(Typography.label).foregroundStyle(palette.ink3).padding(.leading, 4)
                            VStack(spacing: 0) {
                                ForEach(group.tasks) { task in
                                    HoverRow { row(task) }
                                }
                            }
                            .padding(4)
                            .paper(radius: 12)
                        }
                    }
                    if groups?.isEmpty == true {
                        Text(Self.empty).font(Typography.secondary).foregroundStyle(palette.ink3).frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
            .scrollIndicators(.automatic)
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: Self.bottomFade)
                }
            }
        }
        .padding(.top, 18)
        .frame(width: Self.macSize.width).frame(maxHeight: Self.macSize.height)
        .background(palette.desk)
    }
}

/// 行上指针悬停时垫一层淡底。
private struct HoverRow<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var hovered = false
    @Environment(\.palette) private var palette

    var body: some View {
        content.padding(.horizontal, 10).padding(.vertical, 9)
            .background(hovered ? palette.fill : .clear, in: .rect(cornerRadius: 8, style: .continuous))
            .onHover { hovered = $0 }
    }
}
#endif
