#if DEBUG && os(iOS)
import UIKit

nonisolated final class InspirationAuditActivity: UIActivity {
    let destination: URL
    private var files: [URL] = []

    init(destination: URL) { self.destination = destination; super.init() }
    override var activityTitle: String? { "验收保存" }
    override var activityType: UIActivity.ActivityType? { UIActivity.ActivityType("CuePad.InspirationAudit") }
    override var activityImage: UIImage? { Icon.save.platformImage }
    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { activityItems.contains { $0 is URL } }
    override func prepare(withActivityItems activityItems: [Any]) { files = activityItems.compactMap { $0 as? URL } }
    override func perform() {
        do {
            for (index, file) in files.enumerated() {
                let data = try Data(contentsOf: file)
                try data.write(to: destination.appending(path: "system-consumed-\(index).\(file.pathExtension)"))
            }
            try JSONEncoder().encode(files.map(\.lastPathComponent)).write(to: destination.appending(path: "system-consumed-names.json"))
            activityDidFinish(true)
        } catch {
            assertionFailure("系统分享验收没有读完文件：\(error)")
            activityDidFinish(false)
        }
    }
}
#endif
