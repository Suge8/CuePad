import CueStore
import SwiftUI

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
