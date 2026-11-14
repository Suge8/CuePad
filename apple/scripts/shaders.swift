// App 运行时才编的着色器源码（Swift 文件里那一段 #"""…"""#，如 FigureShaders）在这里用本机的 Metal 编一遍：写错在 xc.sh check 就红，不等 App 跑起来才崩。
// 不走 .metal 文件：那要另装 Metal 编译工具链，本机与 CI 都多一份依赖。
// 用法：shaders <Swift 文件…>（xc.sh check 编好这个脚本、把含 metal_stdlib 的 Swift 文件都交给它）。
// 没有 Metal 设备的机器（云端虚拟机）说一句跳过：合并前的签核在本机跑 check，那里一定编过。
import Foundation
import Metal

guard let device = MTLCreateSystemDefaultDevice() else {
    print("着色器：这台机器没有 Metal 设备，跳过（本机签核时编过）")
    exit(0)
}
var failed = false
for path in CommandLine.arguments.dropFirst() {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    guard let start = text.range(of: "#\"\"\"\n"), let end = text.range(of: "\n\"\"\"#", range: start.upperBound..<text.endIndex) else {
        print("\(path)：没找到 #\"\"\" 与 \"\"\"# 之间的着色器源码（收尾的 \"\"\"# 顶格写）")
        failed = true
        continue
    }
    do {
        _ = try device.makeLibrary(source: String(text[start.upperBound..<end.lowerBound]), options: nil)
    } catch {
        print("\(path)：着色器编不过（行号从 #\"\"\" 的下一行数起）\n\(error.localizedDescription)")
        failed = true
    }
}
exit(failed ? 1 : 0)
