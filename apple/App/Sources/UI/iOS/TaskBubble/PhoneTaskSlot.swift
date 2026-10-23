#if os(iOS)
import SwiftUI

/// 手机窄屏的任务浮窗挂在窗口上的那一格（`IOSRoot` 窄屏时挂它，宽屏挂 `TaskBubbleSlot`）：只有它读 `Workspace.openTask`。
/// 原型（proto/task-bubble，不进主干）：两种摆法摆同一份内容（`PhoneTask`），`-CuePadProtoBubble P|Q` 选，都画在气泡那一层（`PanelStyle.bubble`）：
/// 开合只挪图层、不经 UIKit 的呈现；键盘升起时整块挪到键盘之上（`BubbleStage.floor`），字不重排。
/// - P：从点按处长出、带尾巴的气泡（与 Mac 同一种），下一步跟在内容后面。
/// - Q：贴在底部的纸（`BubbleSource.bottom`），下一步在拇指够得着的底部；拖顶上的把手往下关（`BubbleDrag`）。
///   不用系统 sheet（实测）：iOS 26 的纸在矮的那几档整张缩小约 3.5%、键盘一起就放回原大，字跟着缩放；开一次的指令数是自绘的近 3 倍、关一次十几倍。
struct PhoneTaskSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        if DebugHooks.preset.protoBubble == "Q" {
            Color.clear.panel(item: $workspace.openTask, style: .bubble(.bottom)) { request in
                PhoneTask(request: request) { page, footer in
                    VStack(alignment: .leading, spacing: 0) {
                        Grabber()
                        page
                        footer.padding(.leading, PhoneTaskPage.textLeading).padding(.trailing, 12).padding(.top, 12)
                    }
                    .padding(EdgeInsets(top: 0, leading: 8, bottom: 26, trailing: 8))
                }
            }
        } else {
            Color.clear.panel(item: $workspace.openTask, style: .bubble(workspace.openTask?.source ?? .unanchored)) { request in
                PhoneTask(request: request) { page, footer in
                    VStack(alignment: .leading, spacing: 12) {
                        page
                        footer.padding(.leading, PhoneTaskPage.textLeading).padding(.trailing, 12)
                    }
                    .padding(EdgeInsets(top: 6, leading: 6, bottom: 14, trailing: 6))
                }
            }
        }
    }
}

/// Q 的纸顶上的把手：整条横着都接拖动（往下关），只画中间一小截。
private struct Grabber: View {
    @Environment(\.bubbleDrag) private var drag
    @Environment(\.palette) private var palette

    var body: some View {
        Capsule().fill(palette.track).frame(width: 36, height: 5)
            .frame(maxWidth: .infinity).frame(height: 18, alignment: .bottom)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { drag?.changed($0.translation.height) }
                    .onEnded { drag?.ended($0.translation.height, $0.predictedEndTranslation.height) })
            .accessibilityHidden(true)
    }
}
#endif
