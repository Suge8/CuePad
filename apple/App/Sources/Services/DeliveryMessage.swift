#if os(macOS)
import CueStore
import CueBridge
import Foundation

enum DeliveryMessage {
    static func make(_ stored: String, request: DeliveryRequest, session: Session, files: AttachmentFiles) throws -> SessionMessage {
        let content = SendContent(stored: stored), seesImages = session.capabilities.contains(.images)
        let text = try content.agentText(from: files, imagesAsFiles: !seesImages).trimmingCharacters(in: .whitespacesAndNewlines)
        return SessionMessage(text: text, images: seesImages ? try content.messageImages(from: files) : [], deliveryID: request.id.uuidString)
    }
}
#endif
