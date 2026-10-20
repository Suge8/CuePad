import CueEditor
import CueStore
import Foundation

extension AttachmentFiles {
    /// 本机上的原图字节（`original(hash:)`）；不在本机时抛给人看的 `SendError.imageUnavailable`。
    func original(_ hash: String) throws -> Data {
        do { return try original(hash: hash) } catch { throw SendError.imageUnavailable(hash) }
    }

    func png(_ hash: String) throws -> Data {
        guard let png = ImageFiles.png(from: try original(hash)) else { throw SendError.imageUnavailable(hash) }
        return png
    }
}
