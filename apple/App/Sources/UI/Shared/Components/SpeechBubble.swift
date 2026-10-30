import CueStore
import SwiftUI

/// 你说出去的一句（会话页末尾还没进对话的话、Cue 页里你的话）：全 App 只此一个，状态只从记录推出（`Speech`）。
/// 到哪了画在气泡上（`BubbleTrip`；已送达只在 `showsDelivered` 时）；没能送达时原因常驻气泡下方，并显示"未送达 · 重发"；移除在叹号的菜单里。
/// 等待到点只显示静态未确认；再说一次须确认重复风险，保留原记录。晚到回执照常收敛。
struct SpeechBubble<Menu: View>: View {
    let said: Said
    /// 重发时撤回了旧的却写不进新的：原文放回这个去处的输入框。
    let box: Binding<ComposerDraft>
    /// 已送达标不标：会话页每句都标（进了对话就不在这里），Cue 页只标你最后一句（旧的不标，免得满屏）。
    var showsDelivered = true
    /// 收这句话的会话（会话页；在路上时说法分送达中、正在唤醒，`PiDelivery.Transit.of`）；Cue 页的话不分唤醒，同样可显示未确认。
    var session: PiSessionState?
    var fromCue = false
    let look: BubbleLook
    /// 长按菜单（消息菜单）；给的是此刻到哪了。
    @ViewBuilder var menu: (Speech.Trip) -> Menu
    @State private var confirmingAgain = false
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    /// 刚从刻度滑条跳到的那一句（Cue 页里你的话）描一圈。
    @Environment(\.chatHighlight) private var highlight

    var body: some View {
        let trip = said.trip(at: services.speech), shown = bubble(trip)
        VStack(alignment: .trailing, spacing: look.statusSpacing) {
            UserBubble(stored: said.content, look: look, trip: shown, highlighted: highlight == said.id, fromCue: fromCue) { menu(trip) }
            if case .preparing(let reason) = trip {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(verbatim: reason)
                    Button("撤回", action: remove).buttonStyle(PressStyle(.inline))
                }
                .font(Typography.caption).foregroundStyle(palette.ink3).padding(.trailing, look.statusInset)
            } else if let reason = trip.unconfirmedReason {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(verbatim: reason)
                    Button("再说一次…") { confirmingAgain = true }.buttonStyle(PressStyle(.inline))
                }
                .font(Typography.caption).foregroundStyle(palette.ink3).padding(.trailing, look.statusInset)
            } else if case .failed(let undelivered) = shown { failedLine(undelivered).padding(.trailing, look.statusInset) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // 会话页新到的淡入（Cue 页这一句挂在格子里面，过渡不播，由回复框那头的发出动画接上）
        .transition(.entry)
        .dialog("再说一次？", isPresented: $confirmingAgain, message: "上一句可能已经执行，再说一次可能让 Agent 重复操作。原请求会保留。", buttons: [
            DialogButton(title: "再说一次") { workspace.sayAgain(said, restoringInto: box) },
        ])
    }

    private func bubble(_ trip: Speech.Trip) -> BubbleTrip {
        switch trip {
        case .sending, .sent:
            if case .request(let request) = said { .sending(.of(request, session: session, trip: trip)) } else { .sending(trip == .sent ? .sent : .sending) }
        case .preparing: .arrived
        case .unconfirmed: .sending(.unconfirmed)
        case .delivered: showsDelivered ? .delivered(said.roundTrip.map { PiClock.duration(Double($0.components.seconds)) }) : .arrived
        case .failed(let failure):
            .failed(Undelivered(reason: failure.text, resend: resend, remove: remove))
        }
    }

    /// 原因常驻；重发仍是行里的字，不画胶囊，点按区放大而不撑高这一行。
    private func failedLine(_ undelivered: Undelivered) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(verbatim: undelivered.reason)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 0) {
                Text("未送达，")
                Button(MessageMenu.Item.resend.title, action: undelivered.resend)
                    .fontWeight(.semibold)
                    .buttonStyle(PressStyle(.inline))
                    .contentShape(.rect.inset(by: -14))
            }
        }
        .font(Typography.caption).foregroundStyle(palette.failure)
    }

    private func resend() { workspace.resend(said, restoringInto: box) }
    private func remove() { workspace.remove(said) }
}

nonisolated extension Speech.Failure {
    var text: String { switch self { case .reported(let reason): reason } }
}
