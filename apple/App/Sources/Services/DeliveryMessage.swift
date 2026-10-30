#if os(macOS)
import CueStore
import CuePi
import Foundation

enum DeliveryMessage {
    static func make(_ stored: String, request: DeliveryRequest, session: PiSession, files: AttachmentFiles) throws -> PiMessage {
        let content = SendContent(stored: stored), seesImages = session.capabilities.contains(.images)
        let text = try content.agentText(from: files, imagesAsFiles: !seesImages).trimmingCharacters(in: .whitespacesAndNewlines)
        return PiMessage(text: text, images: seesImages ? try content.piImages(from: files) : [], deliveryID: request.id.uuidString)
    }
}
#endif
