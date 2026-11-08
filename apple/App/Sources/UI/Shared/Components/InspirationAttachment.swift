import SwiftUI

struct InspirationImage: View {
    let key: String
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.openPreview) private var openPreview
    @State private var place = AttachmentPlace.unchecked
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Button {
                    workspace.openAttachment(DraftFile(key: key, name: ""), group: key, with: openPreview)
                } label: {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                }
                .buttonStyle(PressStyle(.card))
                .accessibilityLabel("查看图片")
            } else {
                Button { workspace.fetchFile(key) } label: { Label(services.awayLine(key), icon: .attachment) }
                    .buttonStyle(PressStyle())
            }
        }
        .observingArrival(of: key, in: services, into: $place)
        .task(id: place) { image = await Thumbnail.picture(key, height: Spacing.reading, scale: 2, in: services.store.files) }
    }
}

struct InspirationFile: View {
    let file: DraftFile
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.openPreview) private var openPreview
    @State private var place = AttachmentPlace.unchecked

    var body: some View {
        Button { workspace.openAttachment(file, group: file.key, with: openPreview) } label: {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Label(file.name, icon: .attachment)
                if place.isAway { Text(services.awayLine(file.key)).font(Typography.caption) }
            }
        }
        .buttonStyle(PressStyle())
        .font(Typography.secondary)
        .observingArrival(of: file.key, in: services, into: $place)
    }
}
