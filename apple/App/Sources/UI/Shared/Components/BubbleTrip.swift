import CueStore
import SwiftUI

/// 你的话到哪了（气泡自己画出来）：进了对话、在路上（会话这边的说法，`PiDelivery.Transit`）、已送达（来回用时）、没能送达。
/// 记号在气泡左下角外（`TripMark`），"发出"一族只有纸飞机：还没出这台设备是一架一趟趟飞过的小飞机（`LoopLayer.flight`，与发送钮、会话状态标里的话在路上同一个）；
/// 出了这台（已发出、送达中）飞机停下、旁边写着到了哪一步——话 0.4 秒就到服务器，回执要等那台 Mac，看得出不是卡在本机；
/// 等待到点只显示静态未确认，不提供安全重发。唤醒已结束的会话比送达多一步（后台起 Agent，手机上还隔着同步往返），飞着带上说法，免得看着像卡住；
/// 已送达是停下来带勾的那架（用时给读屏与 Mac 的悬停说明）；没能送达胭脂叹号，点它是原因全文与重发、移除。
/// 明确失败在下面常驻原因与"未送达 · 重发"；未确认常驻说明与须确认风险的"再说一次"（`SpeechBubble`）。
enum BubbleTrip: Hashable {
    case arrived
    case sending(PiDelivery.Transit)
    case delivered(String?)
    case failed(Undelivered)

    /// 在路上的话（字与图）整块淡一些，还没落进对话；送达那一刻显出实色。淡到字仍够 4.5:1（浅色 5.4、深色 6.0）：没网时它会停很久，要读得清。
    var opacity: CGFloat { if case .sending = self { 0.7 } else { 1 } }
}

/// 没能送达的这一句：原因全文与能做的事（叹号的菜单、气泡下那一行共用）。只按原因比较：动作随每次求值新建，比它们会让记号每次都重画。
struct Undelivered: Hashable {
    let reason: String
    let resend: () -> Void
    let remove: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.reason == rhs.reason }
    func hash(into hasher: inout Hasher) { hasher.combine(reason) }
}

extension View {
    /// 挂在左边、不占排版（右缘离它 8 点，下沿离它的下沿 `above`，对着最后一行字）：状态一变气泡不重排，对话不跳。
    func tripMark(_ trip: BubbleTrip, above: CGFloat) -> some View {
        overlay(alignment: .bottomLeading) {
            TripMark(trip: trip).alignmentGuide(.leading) { $0[.trailing] + 8 }.padding(.bottom, above)
        }
    }
}

private struct TripMark: View {
    let trip: BubbleTrip
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch trip {
            case .arrived: EmptyView()
            case .sending(let transit):
                HStack(spacing: 4) {
                    OnTheWay(size: 13, color: palette.ink3, landed: transit == .sent || transit == .delivering || transit == .unconfirmed)
                    if transit != .sending { Text(transit.label).fixedSize() }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(transit.label)
            case .delivered(let roundTrip):
                let said = Dotted(String(localized: "已送达"), roundTrip)
                Image(.delivered).accessibilityLabel(Text(said))
                    #if os(macOS)
                    .help(said.visible)
                    #endif
            case .failed(let undelivered):
                Menu {
                    Section(undelivered.reason) {
                        Button(MessageMenu.Item.resend.title, icon: MessageMenu.Item.resend.icon, action: undelivered.resend)
                        Button(MessageMenu.Item.remove.title, icon: MessageMenu.Item.remove.icon, role: .destructive, action: undelivered.remove)
                    }
                } label: {
                    PiStateGlyph.undelivered
                }
                .menuStyle(.button).buttonStyle(PressStyle(.inline))
                #if os(macOS)
                .menuIndicator(.hidden)
                #endif
                .fixedSize()
                // 点按区放大到 44 点，记号本身不变大、不挪位
                .contentShape(.rect.inset(by: -14))
                .accessibilityLabel("没能送达")
                .accessibilityValue(undelivered.reason)
            }
        }
        .font(Typography.caption).foregroundStyle(palette.ink3)
        // 与气泡显出实色同一拍换记号（飞着的 → 停下带勾的），旧的先淡掉
        .transition(.handOff)
        .id(trip)
    }
}

