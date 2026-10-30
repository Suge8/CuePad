import CueStore
import SwiftUI

/// 没有明确周期的计量、余额与文本只显示提供方的读数，不参与匀速线与额度环。
struct QuotaValueRow: View {
    let value: QuotaDetails.Value
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MetaLine(gap: 8) {
                Text(verbatim: value.name).foregroundStyle(palette.ink2)
            } meta: {
                reading.foregroundStyle(palette.ink).monospacedDigit()
            }
            .font(Typography.meta)
            if let resetsAt = value.resetsAt {
                LiveText(style: QuotaMeter.Countdown(end: resetsAt)) { Text("\($0)后重置") }
                    .font(Typography.meta).foregroundStyle(palette.ink3)
            }
        }
    }

    private var reading: Text {
        if let display = value.display { return Text(verbatim: display) }
        if value.unlimited == true { return Text("不限量") }
        if let balance = value.balance { return Text("\(balance.formatted()) \(value.unit ?? "")") }
        if let used = value.used { return Text("剩 \((1 - min(used, 1)).formatted(.percent.precision(.fractionLength(0))))") }
        return Text("尚未观测到额度")
    }
}
