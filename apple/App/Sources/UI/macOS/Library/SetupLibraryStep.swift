#if os(macOS)
import CueStore
import SwiftUI

struct SetupLibraryStep: View {
    let library: AgentLibrary
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            TidyFacts(tidies: library.automaticTidies, library: library)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.inset).padding(.vertical, Spacing.item)
                .background(palette.paper, in: .rect(cornerRadius: Radius.block))
            if !library.selfManaged.isEmpty {
                Text(verbatim: untouched).font(Typography.meta).foregroundStyle(palette.ink3).padding(.horizontal, Spacing.tight)
            }
        }
    }

    private var untouched: String {
        let parts = library.selfManaged.map(\.title)
        return String(localized: "不动：\(parts.formatted(.list(type: .and)))，由它们自己管")
    }
}
#endif
