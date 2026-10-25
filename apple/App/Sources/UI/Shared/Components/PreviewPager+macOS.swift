#if os(macOS)
import CueStore
import SwiftUI

extension View {
    /// 点交付物后的全屏页：窗口内浮层（`panel`），同一组的几份用右上的前后箭头翻；每类怎么显示见 `PreviewPage`。
    /// `reply` 是这一页的底栏对谁说（`PreviewOpening.reply` 另给的除外）。一个页面只在这里挂一次，不在每张缩略图上各挂一个。
    func previewPresenter(_ opened: Binding<PreviewOpening?>, reply: PreviewReply) -> some View {
        modifier(PreviewPresenter(opened: opened, reply: reply))
    }
}

private struct PreviewPresenter: ViewModifier {
    @Binding var opened: PreviewOpening?
    let reply: PreviewReply
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .environment(\.openPreview, PreviewOpener { opened = $0 })
            .panel(item: $opened, style: .fullScreen) {
                PreviewPager(opening: $0, reply: $0.reply ?? reply, current: $0.preview.id)
                    .frame(maxWidth: 960, maxHeight: 760)
                    .background(palette.desk)
            }
    }
}

/// 全屏页：顶上是各浮层统一的那一行（`PanelHeader`：标题居中，前后箭头、分享与关闭在右上），标题是当前这一份（写法同缩略图下那行），
/// 内容紧接着铺满，底部一条玻璃栏（`PreviewReplyBar`）。
private struct PreviewPager: View {
    let opening: PreviewOpening
    let reply: PreviewReply
    @State var current: UUID
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.closePanel) private var close

    private var batch: [PiPreview] { opening.batch }
    private var index: Int { opening.index(of: current) }
    private var preview: PiPreview { batch[index] }
    private var title: String { opening.title(of: preview) }

    var body: some View {
        VStack(spacing: 10) {
            PanelHeader(title: title) {
                stepper
                if let file = file(of: preview) {
                    ShareLink(item: file) { Image(.share).accessibilityLabel("分享") }
                }
            }
            .buttonStyle(PressStyle(.inline)).foregroundStyle(palette.ink2)
            PreviewContent(preview: preview, file: file(of: preview)).id(preview.id)
            PreviewReplyBar(reply: reply, about: title, done: { close() })
                .frame(maxWidth: 640).padding([.horizontal, .bottom], 16)
        }
        .padding(.top, 14)
        .background(palette.desk)
    }

    /// 前后箭头夹着"第几份 · 类型"。
    @ViewBuilder private var stepper: some View {
        if batch.count > 1 { Button("上一个", icon: .back) { step(-1) }.labelStyle(.iconOnly).disabled(index == 0) }
        Text(opening.position(at: index)).font(Typography.caption).foregroundStyle(palette.ink3).monospacedDigit()
        if batch.count > 1 { Button("下一个", icon: .forward) { step(1) }.labelStyle(.iconOnly).disabled(index == batch.count - 1) }
    }

    private func step(_ offset: Int) {
        withAnimation(HandOff.quick) { current = batch[index + offset].id }
    }

    private func file(of preview: PiPreview) -> URL? {
        services.store.files.url(of: preview)
    }
}
#endif
