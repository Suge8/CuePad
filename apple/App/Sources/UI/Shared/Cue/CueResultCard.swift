import CueStore
import SwiftUI

/// 结果卡：挂着交付物的 Cue 的话（哪句挂哪几份只在 `CueThread.rows` 定）。一张纸，上面是那句话（Cue 做完时是"「X」做完了"与证据），
/// 中间是交付物（`DeliverableStrip`），末行是这件活（点开任务）。自成一行，不进气泡：靠左、最宽与 Cue 的气泡同一栏比例，
/// 字与气泡里的字、旁注的图标对齐（`Bubble.padding`）；点一份放大到全屏，底栏是关于它对 Cue 说。
struct CueResultCard: View {
    let message: CueMessage
    let ref: CueTaskRef
    let deliverables: [PiPreview]
    let open: (PreviewOpening) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        BubbleWidth(fraction: Bubble.cueWidth, edge: .leading) {
            VStack(alignment: .leading, spacing: 10) {
                MarkdownText(source: message.text).equatable()
                    .contextMenu { MessageActions(text: message.text, kind: .cue) }
                DeliverableStrip(previews: deliverables, size: .result, group: message.id.uuidString, bleed: Bubble.padding.leading) {
                    open(PreviewOpening(preview: $0, batch: deliverables, group: message.id.uuidString, reply: .cue))
                }
                CueTaskLine(ref: ref)
            }
            .padding(Bubble.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper(radius: Bubble.radius)
        }
        .transition(Bubble.arrival(.leading, reduceMotion: reduceMotion))
    }
}
