import CueStore
import CueSync
import CueText
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
    /// 还在路上时的说法（会话：发送中、送达中、正在唤醒，`PiDelivery.Transit`）；Cue 页的话只有发送中。
    var transit = PiDelivery.Transit.sending
    var fromCue = false
    let look: BubbleLook
    /// 长按菜单（消息菜单）；给的是此刻到哪了。
    @ViewBuilder var menu: (Speech.Trip) -> Menu
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 刚从刻度滑条跳到的那一句（Cue 页里你的话）描一圈。
    @Environment(\.chatHighlight) private var highlight

    var body: some View {
        let trip = said.trip(at: services.speech), shown = bubble(trip)
        VStack(alignment: .trailing, spacing: look.statusSpacing) {
            UserBubble(stored: said.content, look: look, trip: shown, highlighted: highlight == said.id, fromCue: fromCue) { menu(trip) }
            if case .failed(let undelivered) = shown { failedLine(undelivered).padding(.trailing, look.statusInset) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .transition(look.arrival(reduceMotion: reduceMotion))
    }

    private func bubble(_ trip: Speech.Trip) -> BubbleTrip {
        switch trip {
        case .sending: .sending(transit)
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
                .buttonStyle(.plain)
                .contentShape(.rect.inset(by: -14))
                .disabled(!undelivered.canResend)
        }
        .font(Typography.caption).foregroundStyle(palette.failure)
    }

    private func resend() { workspace.resend(said, restoringInto: box) }
    private func remove() { workspace.remove(said) }
}

nonisolated extension Speech.Failure {
    /// 没能送达的原因：Mac 写回的原文；超时的只分本机同步不通与 Mac 一直没收下（只说这句话，不猜 Mac 在不在：那台 Mac 在不在线看它的在线记录）。
    /// 同步不通写同步状态那套说法（`sync` 此刻的状态）。
    func text(sync: SyncStatus) -> String {
        reason ?? "\(SyncSummary(sync).title)，发不到 Mac"
    }

    /// 这一句自己的原因（Mac 写回的、Mac 一直没收下）；本机同步不通是全局的事，不是哪一句的原因，没有（nil）。
    var reason: String? {
        switch self {
        case .reported(let reason): reason
        case .offline: nil
        case .timedOut: "Mac 迟迟没收下这句"
        }
    }
}
