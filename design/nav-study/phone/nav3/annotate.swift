// 一次性工具（只在 proto/head-phone2）：把同一屏的现状与方案截图上下排成一组，编号圆章贴在被指的那一处旁边，说明按编号排在右边。
// 用法：swift annotate.swift <方案.json>。截图是 3x 的 402×874pt 画面，json 里的坐标按点给。
// 每张截图只取 regions 里的几段（[上, 下]，点）；guide 是内容起点那条虚线（点）与它的标注。
import AppKit

struct Note: Decodable { let x: CGFloat; let y: CGFloat; let text: String }
struct Panel: Decodable { let tag: String; let image: String; var guide: CGFloat?; var guideText: String?; var notes: [Note]? }
struct Block: Decodable { let label: String; let regions: [[CGFloat]]; let panels: [Panel] }
struct Spec: Decodable { let title: String; let summary: String; let out: String; let blocks: [Block] }

let specURL = URL(fileURLWithPath: CommandLine.arguments[1])
let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: specURL))
let base = specURL.deletingLastPathComponent()

let width: CGFloat = 1290
let shotWidth: CGFloat = 600
let scale = shotWidth / 402
let margin: CGFloat = 44
let textX = margin + shotWidth + 56
let textWidth = width - textX - margin
let regionGap: CGFloat = 26
let tagHeight: CGFloat = 64
let panelGap: CGFloat = 34
let labelHeight: CGFloat = 92
let blockGap: CGFloat = 80

let ink = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
let ink3 = NSColor(srgbRed: 0.42, green: 0.42, blue: 0.44, alpha: 1)
let accent = NSColor(srgbRed: 0.20, green: 0.30, blue: 0.62, alpha: 1)  // 靛青
let warn = NSColor(srgbRed: 0.72, green: 0.38, blue: 0.10, alpha: 1)
let paper = NSColor(srgbRed: 0.97, green: 0.96, blue: 0.94, alpha: 1)
func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
    NSFont(name: bold ? "PingFangSC-Semibold" : "PingFangSC-Regular", size: size) ?? .systemFont(ofSize: size)
}
func attributed(_ text: String, _ size: CGFloat, bold: Bool = false, color: NSColor = ink) -> NSAttributedString {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = size * 0.25
    return NSAttributedString(string: text, attributes: [.font: font(size, bold: bold), .foregroundColor: color, .paragraphStyle: style])
}
func textHeight(_ text: NSAttributedString, _ width: CGFloat) -> CGFloat {
    text.boundingRect(with: NSSize(width: width, height: 4000), options: [.usesLineFragmentOrigin]).height
}

func shotsHeight(_ block: Block) -> CGFloat {
    block.regions.map { ($0[1] - $0[0]) * scale }.reduce(0, +) + regionGap * CGFloat(block.regions.count - 1)
}
/// 截图上的一点（点）落在拼出来的那一列的哪儿；不在任何一段里为 nil。
func place(_ y: CGFloat, _ block: Block, top: CGFloat) -> CGFloat? {
    var cursor = top
    for region in block.regions {
        if y >= region[0], y <= region[1] { return cursor + (y - region[0]) * scale }
        cursor += (region[1] - region[0]) * scale + regionGap
    }
    return nil
}
func notesHeight(_ panel: Panel) -> CGFloat {
    (panel.notes ?? []).map { max(textHeight(attributed($0.text, 40), textWidth - 66), 56) + 34 }.reduce(0, +)
}
func panelHeight(_ panel: Panel, _ block: Block) -> CGFloat { tagHeight + max(shotsHeight(block), notesHeight(panel)) }
func blockHeight(_ block: Block) -> CGFloat {
    labelHeight + block.panels.map { panelHeight($0, block) }.reduce(0, +) + panelGap * CGFloat(block.panels.count - 1) + blockGap
}
let titleText = attributed(spec.title, 58, bold: true)
let summaryText = attributed(spec.summary, 40, color: ink3)
let titleHeight = 50 + textHeight(titleText, width - margin * 2) + 18 + textHeight(summaryText, width - margin * 2) + 50
let height = titleHeight + spec.blocks.map(blockHeight).reduce(0, +)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: rep)!
context.cgContext.translateBy(x: 0, y: height)
context.cgContext.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)

paper.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
var top: CGFloat = 50
titleText.draw(with: NSRect(x: margin, y: top, width: width - margin * 2, height: 400), options: [.usesLineFragmentOrigin])
top += textHeight(titleText, width - margin * 2) + 18
summaryText.draw(with: NSRect(x: margin, y: top, width: width - margin * 2, height: 400), options: [.usesLineFragmentOrigin])
top = titleHeight

func badge(_ number: Int, at center: CGPoint, radius: CGFloat) {
    let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    accent.setFill()
    ring.fill()
    NSColor.white.setStroke()
    ring.lineWidth = 4
    ring.stroke()
    let label = attributed("\(number)", radius * 1.25, bold: true, color: .white)
    let size = label.size()
    label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
}

func pill(_ text: String, rightAt x: CGFloat, centerY y: CGFloat, color: NSColor) {
    let label = attributed(text, 30, bold: true, color: .white)
    let size = label.size()
    let rect = NSRect(x: x - size.width - 28, y: y - size.height / 2 - 6, width: size.width + 20, height: size.height + 12)
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    label.draw(at: CGPoint(x: rect.minX + 10, y: rect.minY + 6))
}

for block in spec.blocks {
    attributed(block.label, 46, bold: true).draw(in: NSRect(x: margin, y: top + 10, width: width - margin * 2, height: 80))
    var panelTop = top + labelHeight
    for panel in block.panels {
        let current = panel.notes == nil
        attributed(panel.tag, 36, bold: true, color: current ? ink3 : accent).draw(in: NSRect(x: margin, y: panelTop + 6, width: shotWidth, height: 56))
        let shotTop = panelTop + tagHeight
        let image = NSImage(contentsOf: base.appendingPathComponent(panel.image))!
        var cursor = shotTop
        for region in block.regions {
            let h = (region[1] - region[0]) * scale
            let frame = NSRect(x: margin, y: cursor, width: shotWidth, height: h)
            let source = NSRect(x: 0, y: image.size.height - region[1] / 874 * image.size.height, width: image.size.width,
                                height: (region[1] - region[0]) / 874 * image.size.height)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: frame, xRadius: 30, yRadius: 30).addClip()
            image.draw(in: frame, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            NSColor(white: 0, alpha: 0.14).setStroke()
            let edge = NSBezierPath(roundedRect: frame, xRadius: 30, yRadius: 30)
            edge.lineWidth = 2
            edge.stroke()
            cursor += h + regionGap
        }
        if let guide = panel.guide, let y = place(guide, block, top: shotTop) {
            let color = current ? warn : accent
            color.setStroke()
            let line = NSBezierPath()
            line.move(to: CGPoint(x: margin, y: y))
            line.line(to: CGPoint(x: margin + shotWidth, y: y))
            line.lineWidth = 4
            line.setLineDash([16, 10], count: 2, phase: 0)
            line.stroke()
            pill(panel.guideText ?? "内容从 \(Int(guide)) 起", rightAt: margin + shotWidth, centerY: y + 30, color: color)
        }
        var noteY = shotTop
        for (index, note) in (panel.notes ?? []).enumerated() {
            if let y = place(note.y, block, top: shotTop) { badge(index + 1, at: CGPoint(x: margin + note.x * scale, y: y), radius: 22) }
            let text = attributed(note.text, 40)
            let h = textHeight(text, textWidth - 66)
            badge(index + 1, at: CGPoint(x: textX + 26, y: noteY + 30), radius: 26)
            text.draw(with: NSRect(x: textX + 66, y: noteY + 4, width: textWidth - 66, height: h + 10), options: [.usesLineFragmentOrigin])
            noteY += max(h, 56) + 34
        }
        panelTop += panelHeight(panel, block) + panelGap
    }
    top += blockHeight(block)
}

NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: base.appendingPathComponent(spec.out))
print(base.appendingPathComponent(spec.out).path)
