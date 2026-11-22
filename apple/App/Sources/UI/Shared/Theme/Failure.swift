import SwiftUI

struct FailureMark: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Image(.failure).foregroundStyle(palette.failure).readerHidden(true)
    }
}
