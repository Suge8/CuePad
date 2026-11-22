import CueText
import Foundation
import UniformTypeIdentifiers

extension Icon {
    static func file(named name: String) -> Icon {
        guard let type = AttachmentKey.type(ofName: name) else { return .file }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .audiovisualContent) { return .play }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) { return .document }
        return .file
    }
}
