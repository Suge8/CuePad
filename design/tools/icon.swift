// 一次性资产工具：从黑白 logo 图提取 mark（亮度→alpha），生成
// 1) 1024 应用图标：白色 squircle + 居中黑 mark（透明背景）
// 2) 44px 托盘模板图标：纯黑 + alpha
// 3) 应用内品牌 mark（黑 + alpha，前端用 CSS mask 着 currentColor）
import AppKit

func die(_ msg: String) -> Never {
	FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
	exit(1)
}

let args = CommandLine.arguments
guard args.count == 5 else { die("usage: icon <logo.png> <icon-out.png> <tray-out.png> <mark-out.png>") }

guard let src = NSImage(contentsOfFile: args[1]),
	let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { die("cannot read \(args[1])") }

// --- 提取 mark：黑色像素 → 不透明黑，白色 → 透明；顺带求内容包围盒 ---
let w = cg.width, h = cg.height
var pixels = [UInt8](repeating: 0, count: w * h * 4)
let srcCtx = CGContext(
	data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
	space: CGColorSpace(name: CGColorSpace.sRGB)!,
	bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
srcCtx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h {
	for x in 0..<w {
		let i = (y * w + x) * 4
		let lum = (Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587 + Int(pixels[i + 2]) * 114) / 1000
		// 亮度 200+ 视为背景（源图底色非纯白），40..200 线性过渡保住反锯齿边
		let alpha = UInt8(max(0, min(255, (200 - lum) * 255 / 160)))
		pixels[i] = 0
		pixels[i + 1] = 0
		pixels[i + 2] = 0
		pixels[i + 3] = alpha
		if alpha > 24 {
			minX = min(minX, x); maxX = max(maxX, x)
			minY = min(minY, y); maxY = max(maxY, y)
		}
	}
}
guard minX < maxX else { die("empty mark") }
let markCG = srcCtx.makeImage()!.cropping(
	to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
let markW = Double(markCG.width), markH = Double(markCG.height)

func canvas(_ side: Int) -> CGContext {
	CGContext(
		data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
		space: CGColorSpace(name: CGColorSpace.sRGB)!,
		bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func fitRect(in box: CGRect) -> CGRect {
	let scale = min(box.width / markW, box.height / markH)
	let fw = markW * scale, fh = markH * scale
	return CGRect(x: box.midX - fw / 2, y: box.midY - fh / 2, width: fw, height: fh)
}

func savePNG(_ ctx: CGContext, _ path: String) {
	let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
	try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
	print(path)
}

// --- 应用图标：Big Sur 规范 squircle 824/1024，白底 + 极淡描边 ---
let iconCtx = canvas(1024)
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(
	roundedRect: plate, cornerWidth: 824 * 0.2237, cornerHeight: 824 * 0.2237, transform: nil)
iconCtx.addPath(squircle)
iconCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
iconCtx.fillPath()
iconCtx.addPath(squircle)
iconCtx.setStrokeColor(CGColor(gray: 0, alpha: 0.08))
iconCtx.setLineWidth(4)
iconCtx.strokePath()
iconCtx.interpolationQuality = .high
iconCtx.draw(markCG, in: fitRect(in: plate.insetBy(dx: 824 * 0.15, dy: 824 * 0.15)))
savePNG(iconCtx, args[2])

// --- 托盘模板图标：44px，纯黑 + alpha，留 2px 边距 ---
let trayCtx = canvas(44)
trayCtx.interpolationQuality = .high
trayCtx.draw(markCG, in: fitRect(in: CGRect(x: 2, y: 2, width: 40, height: 40)))
savePNG(trayCtx, args[3])

// --- 品牌 mark：紧贴内容缩放到高 128，黑 + alpha ---
let markScale = 128.0 / markH
let markCtx = CGContext(
	data: nil, width: Int(markW * markScale), height: 128, bitsPerComponent: 8, bytesPerRow: 0,
	space: CGColorSpace(name: CGColorSpace.sRGB)!,
	bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
markCtx.interpolationQuality = .high
markCtx.draw(markCG, in: CGRect(x: 0, y: 0, width: markW * markScale, height: 128))
savePNG(markCtx, args[4])
