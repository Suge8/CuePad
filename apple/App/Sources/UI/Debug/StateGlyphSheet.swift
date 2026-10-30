#if DEBUG
import CueStore
import SwiftUI

/// 状态图形总览（`-CuePadScene stateicons`，iPhone、iPad、Mac 都排得下，一列往下滚）：会话状态（`PiShown.Status` 全部）、Cue 页经过那一行
/// （`CueChange.Kind` 全部，平时灰、还没处理时着色）、Cue 自己的各拍（`CueBeat` 全部，四档头像）。
/// `-CuePadSheetEnd YES` 一打开停在底，一屏放不下时与停在顶的那张拼成整份。
/// 每行画的就是 App 里的那个视图（`PiStateDot`、`CueAvatar`），不另画一份；放不放循环随 `LoopsPlay`。改状态图形、头像各拍后用它对一遍（docs/verify.md）。
struct StateGlyphSheet: View {
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                section("会话状态")
                ForEach(Self.sessions, id: \.0) { name, status in
                    row(name) {
                        PiStateDot(shown: PiShown(status: status), size: 12)
                        PiStateDot(shown: PiShown(status: status), size: 7)
                        Image(PiShown(status: status).icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(PiShown(status: status).tint(palette))
                    }
                }
                section("Cue 页经过（平时 / 还没处理）")
                ForEach(CueChange.Kind.allCases, id: \.self) { kind in
                    row(Self.change(kind)) {
                        Image(kind.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.ink3)
                        if kind != .settled, kind != .done {
                            Image(kind.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(kind.openTint(palette))
                        }
                    }
                }
                section("Cue 自己（64 / 48 / 32 / 16）")
                ForEach(CueBeat.allCases, id: \.self) { beat in
                    row(Self.beat(beat), height: 70) {
                        CueAvatar(beat, size: .card)
                        CueAvatar(beat, size: .header)
                        CueAvatar(beat, size: .row)
                        CueAvatar(beat, size: .inline)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 24)
        }
        // 一屏放不下时截两张：`-CuePadSheetEnd YES` 停在底
        .defaultScrollAnchor(DebugScene.defaults.bool(forKey: "CuePadSheetEnd") ? .bottom : .top)
        .background(palette.desk)
        .foregroundStyle(palette.ink)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(palette.ink2).padding(.top, 14)
    }

    private func row(_ name: String, height: CGFloat = 26, @ViewBuilder marks: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(name).font(.system(size: 12)).frame(width: 96, alignment: .leading).lineLimit(1)
            HStack(spacing: 12, content: marks)
        }
        .frame(minHeight: height)
    }

    private static let sessions: [(String, PiShown.Status)] = [
        ("在跑", .working(.thinking)),
        ("压缩上下文", .working(.compacting)),
        ("等子代理", .working(.delegating)),
        ("话在路上", .delivery(.inTransit(.sending))),
        ("等你确认", .asking),
        ("待回复", .awaitsReply),
        ("该你了", .idle),
        ("等 Cue 回答", .cueAsking),
        ("有新回复", .unread),
        ("出错", .failed(.other)),
        ("没能送达", .delivery(.failed(.reported(DeliveryRequest.unexplainedFailure)))),
        ("被打断", .interrupted),
        ("歇着", .resting),
        ("新会话", .fresh),
        ("已结束", .ended),
        ("未知", .unknown),
    ]

    private static func change(_ kind: CueChange.Kind) -> String {
        switch kind {
        case .settled: "停下了"
        case .waitingForUser: "等你"
        case .failed: "出错"
        case .undelivered: "没送到"
        case .done: "做完"
        case .stalled: "子代理卡住了"
        }
    }

    private static func beat(_ beat: CueBeat) -> String {
        switch beat {
        case .resting: "歇着"
        case .hearing: "在听"
        case .thinking: "在想"
        case .delegating: "等子代理"
        case .waiting: "等你"
        case .done: "做完"
        case .failed: "起不来"
        case .away: "不在"
        }
    }
}
#endif
