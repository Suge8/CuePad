import CueStore
import SwiftUI

/// 同步不通不在这里说：说的话照样写下、排着，恢复后自动发出（同对 Cue 说的话）；为什么不通只在同步那一处（`SyncSummary`）。
struct MacInputNotice: View {
    var noMac = false
    var failure: String?
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if noMac {
                Text(CueStoreError.noMac.localizedDescription).foregroundStyle(palette.ink3)
            }
            if let failure {
                Text(failure).foregroundStyle(palette.failure)
            }
        }
        .font(Typography.caption).lineLimit(2)
    }
}
