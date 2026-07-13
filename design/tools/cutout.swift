// 一次性资产工具：Vision 前景抠图 → 裁剪 → 缩放 → 透明 PNG
import AppKit
import Vision

func die(_ msg: String) -> Never {
	FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
	exit(1)
}

let args = CommandLine.arguments
guard args.count == 4, let maxSide = Int(args[3]) else { die("usage: cutout <in> <out> <maxSide>") }

guard let src = NSImage(contentsOfFile: args[1]),
	let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { die("cannot read \(args[1])") }

let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(cgImage: cg)
try! handler.perform([request])
guard let result = request.results?.first else { die("no foreground found") }
let masked = try! result.generateMaskedImage(
	ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true)

let ci = CIImage(cvPixelBuffer: masked)
let context = CIContext()
guard let outCG = context.createCGImage(ci, from: ci.extent) else { die("render failed") }

// 缩放到 maxSide
let w = outCG.width, h = outCG.height
let scale = min(1.0, Double(maxSide) / Double(max(w, h)))
let nw = Int(Double(w) * scale), nh = Int(Double(h) * scale)
let ctx = CGContext(
	data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
	space: CGColorSpace(name: CGColorSpace.sRGB)!,
	bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
ctx.draw(outCG, in: CGRect(x: 0, y: 0, width: nw, height: nh))
let final = ctx.makeImage()!

let rep = NSBitmapImageRep(cgImage: final)
guard let png = rep.representation(using: .png, properties: [:]) else { die("png encode failed") }
try! png.write(to: URL(fileURLWithPath: args[2]))
print("\(args[2]) \(nw)x\(nh)")
