import CueEditor
import CueStore
import Foundation

extension AttachmentFiles {
    /// 本机上的原字节；不在本机时抛给人看的 `SendError.imageUnavailable`。
    func original(_ key: String) throws -> Data {
        guard let url = fileURL(for: key), let data = try? Data(contentsOf: url) else { throw SendError.imageUnavailable(key) }
        return data
    }

    func png(_ key: String) throws -> Data {
        guard let png = ImageFiles.png(from: try original(key)) else { throw SendError.imageUnavailable(key) }
        return png
    }
}
