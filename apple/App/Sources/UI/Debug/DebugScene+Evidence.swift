#if DEBUG
import CueStore
import SwiftUI

extension DebugScene {
    @discardableResult
    static func seedEvidence(_ store: CueStore, session: String, title: String) async -> PiPreview? {
        let file = FileManager.default.temporaryDirectory.appending(path: "cuepad-demo-\(session).png")
        try? swatchPNG().write(to: file)
        return try? await store.addPreviews([(file, title)], sessionID: session).first?.preview
    }

    /// 一张像截图的演示图：浅底上一列名单。
    static func swatchPNG() -> Data {
        let view = VStack(alignment: .leading, spacing: 10) {
            Text("发言顺序").font(.system(size: 22, weight: .bold))
            ForEach(["小林", "阿杰", "Mia", "老王", "Sora", "Kai"], id: \.self) { name in
                HStack { Circle().fill(.indigo.opacity(0.7)).frame(width: 18); Text(name) }
            }
        }
        .padding(24).frame(width: 300, height: 360, alignment: .topLeading).background(Color(red: 0.95, green: 0.96, blue: 1))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.cgImage.map { DemoLibrary.encode($0) } ?? Data()
    }
}
#endif
