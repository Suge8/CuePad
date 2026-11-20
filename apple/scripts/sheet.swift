// 用法：sheet <出.png> [-cols 列数] [-crop 宽x高[+左+上]] <图…>
// 把几张图拼成一张对照图，一次读完：每张先按 -crop 裁（像素，从左上角算），按列数排开（缺省排成一行），各自下面写所在目录与文件名。
// xc.sh sheet 编译并调用它。
import AppKit

var args = Array(CommandLine.arguments.dropFirst())
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...(i + 1)) }
    return args[i + 1]
}

let crop = option("-crop").map { text -> CGRect in
    let n = text.split(whereSeparator: { "x+".contains($0) }).compactMap { Double($0) }
    guard n.count == 2 || n.count == 4 else { fail("-crop 写成 宽x高 或 宽x高+左+上") }
    return CGRect(x: n.count == 4 ? n[2] : 0, y: n.count == 4 ? n[3] : 0, width: n[0], height: n[1])
}
let asked = option("-cols").map { text -> Int in
    guard let n = Int(text), n > 0 else { fail("-cols 后面是列数") }
    return n
}
guard args.count >= 2 else { fail("用法：sheet <出.png> [-cols 列数] [-crop 宽x高[+左+上]] <图…>") }
let out = args.removeFirst()
let tiles = args.map { path -> (name: String, image: CGImage) in
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("读不了 \(path)") }
    if let crop {
        guard let cut = image.cropping(to: crop) else { fail("\(path)（\(image.width)x\(image.height)）裁不出 \(crop)") }
        image = cut
    }
    return (url.deletingPathExtension().pathComponents.suffix(2).joined(separator: "/"), image)
}

let cols = min(asked ?? tiles.count, tiles.count), rows = (tiles.count + cols - 1) / cols
let width = tiles.map(\.image.width).max()!, height = tiles.map(\.image.height).max()!
let gap = 16, type = max(22, width / 28), cell = height + type * 2
let sheet = (width: cols * (width + gap) + gap, height: rows * (cell + gap) + gap)
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: sheet.width, pixelsHigh: sheet.height, bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else { fail("开不出 \(sheet.width)x\(sheet.height) 的画布") }
NSGraphicsContext.current = context
NSColor(white: 0.13, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: sheet.width, height: sheet.height).fill()
let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: CGFloat(type)), .foregroundColor: NSColor.white]
for (i, tile) in tiles.enumerated() {
    // 画布的原点在左下，格子从上往下排
    let x = gap + (i % cols) * (width + gap), top = sheet.height - gap - (i / cols) * (cell + gap)
    context.cgContext.draw(tile.image, in: CGRect(x: x, y: top - tile.image.height, width: tile.image.width, height: tile.image.height))
    (tile.name as NSString).draw(at: NSPoint(x: x, y: top - height - type * 2 + type / 3), withAttributes: label)
}
guard let png = rep.representation(using: .png, properties: [:]) else { fail("编不出 PNG") }
do { try png.write(to: URL(fileURLWithPath: out)) } catch { fail("写不了 \(out)：\(error.localizedDescription)") }
print(out)
