import CueText
import Foundation
import UniformTypeIdentifiers

extension Icon {
    /// 文件的类型记号（文件牌上没有缩略图时），类型只按 `AttachmentKey.type`（与写出的种类同一处）：视频、音频、成页的文稿，其余是文件。
    static func file(named name: String) -> Icon {
        guard let type = AttachmentKey.type(ofName: name) else { return .file }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .audiovisualContent) { return .play }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) { return .document }
        return .file
    }
}
