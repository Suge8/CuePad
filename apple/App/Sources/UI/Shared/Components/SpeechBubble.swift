import CueStore
import CueSync
import SwiftUI

/// 你说出去的一句（会话页末尾还没进对话的话、Cue 页里你的话）：全 App 只此一个，状态只从记录推出（`Speech`）。
/// 到哪了画在气泡上（`BubbleTrip`；已送达只在 `showsDelivered` 时）；没能送达时下面一行"未送达 · 重发"，原因与移除在叹号的菜单里。
/// 到点翻成没能送达靠全 App 一份的此刻（`AppServices.speech`）；超时后回执来了，记录一变就是已送达。
struct SpeechBubble<Menu: View>: View {
    let said: Said
    /// 重发时撤回了旧的却写不进新的：原文放回这个去处的输入框。
    let box: Binding<ComposerDraft>
    /// 已送达标不标：会话页每句都标（进了对话就不在这里），Cue 页只标你最后一句（旧的不标，免得满屏）。
    var showsDelivered = true
    /// 收这句话的会话（会话页；在路上时说法分送达中、正在唤醒，`PiDelivery.Transit.of`）；Cue 页的话没有，只分发送中、已发出。
    var session: PiSessionState?
    var fromCue = false
    let look: BubbleLook
    /// 长按菜单（消息菜单）；给的是此刻到哪了。
    @ViewBuilder var menu: (Speech.Trip) -> Menu
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    /// 刚从刻度滑条跳到的那一句（Cue 页里你的话）描一圈。
    @Environment(\.chatHighlight) private var highlight

    var body: some View {
        let trip = said.trip(at: services.speech), shown = bubble(trip)
        VStack(alignment: .trailing, spacing: look.statusSpacing) {
            UserBubble(stored: said.content, look: look, trip: shown, highlighted: highlight == said.id, fromCue: fromCue) { menu(trip) }
            if case .failed(let undelivered) = shown { failedLine(undelivered).padding(.trailing, look.statusInset) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // 会话页新到的淡入（Cue 页这一句挂在格子里面，过渡不播，由回复框那头的发出动画接上）
        .transition(.entry)
    }

    private func bubble(_ trip: Speech.Trip) -> BubbleTrip {
        switch trip {
        case .sending, .sent:
            if case .request(let request) = said { .sending(.of(request, session: session, trip: trip)) } else { .sending(trip == .sent ? .sent : .sending) }
        case .delivered: showsDelivered ? .delivered(said.roundTrip.map { PiClock.duration(Double($0.components.seconds)) }) : .arrived
        case .failed(let failure):
            .failed(Undelivered(reason: failure.text(sync: services.syncStatus), canResend: services.reachesPiHost, resend: resend, remove: remove))
        }
    }

    /// 一行，和旁注一样高：重发是行里的字，不画胶囊；点按区放大到 44 点而不撑高这一行。送不到 Mac 时也露出来（停用），看得出能重发。
    private func failedLine(_ undelivered: Undelivered) -> some View {
        HStack(spacing: 4) {
            Text("未送达")
            Dot()
            Button(MessageMenu.Item.resend.title, action: undelivered.resend)
                .fontWeight(.semibold)
                .buttonStyle(PressStyle(.inline))
                .contentShape(.rect.inset(by: -14))
                .disabled(!undelivered.canResend)
        }
        .font(Typography.caption).foregroundStyle(palette.failure)
    }

    private func resend() { workspace.resend(said, restoringInto: box) }
    private func remove() { workspace.remove(said) }
}

nonisolated extension Speech.Failure {
    /// 没能送达的原因：Mac 写回的原文；到点的只说这句话自己（不猜 Mac 在不在：那台 Mac 在不在线看它的在线记录）——
    /// 一直没出这台设备时，本机同步此刻不通就写同步状态那套说法（`sync` 此刻的状态），通着就是这句一直没传上去。
    func text(sync: SyncStatus) -> String {
        switch self {
        case .reported(let reason): reason
        case .unsent: sync.reachesMac ? "这句一直没传到 iCloud，发不到 Mac" : "\(SyncSummary(sync).title)，发不到 Mac"
        case .timedOut: "Mac 迟迟没收下这句"
        }
    }
}
