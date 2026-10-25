import CryptoKit
import Darwin
import Foundation

/// 测试里要被运行的脚本（假 Agent、包在 Agent 外面的壳）只经这里放。
/// 系统对新出现的可执行文件或脚本，第一次运行前要检查一遍（syspolicyd，整机共用）：机器忙时一个要排几百毫秒到几秒，
/// 几十个用例同时起就排过了问版本的时限（`AgentIntegration` 的 10 秒）与条件等待（5 秒）。所以脚本按内容在临时目录存一份、
/// 跨运行复用（只第一次被检查），要的位置上放指向它的符号链接（同录像带替身的做法，见 `tape-stub.c`）。
/// 内容因此不能带本次运行的路径（每次不同又成了新文件）：要用的写进 `variables`，放在链接旁的 `<链接>.env`（`NAME='值'` 一行一个），
/// sh 脚本写 `. "$0.env"` 读进来（`$0` 是链接的路径）。
public enum TestScript {
  private static let cache = FileManager.default.temporaryDirectory.appending(path: "cuepad-test-scripts", directoryHint: .isDirectory)

  /// 在 `url` 放内容是 `script`（带 `#!` 行）的可执行脚本，已有的同名文件换掉。
  public static func install(_ script: String, at url: URL, variables: [String: String] = [:]) throws {
    let file = try cached(script)
    let manager = FileManager.default
    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? manager.removeItem(at: url)
    try manager.createSymbolicLink(at: url, withDestinationURL: file)
    if !variables.isEmpty {
      let lines = variables.sorted { $0.key < $1.key }.map { "\($0.key)='\($0.value.replacing("'", with: #"'\''"#))'\n" }
      try Data(lines.joined().utf8).write(to: URL(filePath: url.path + ".env"))
    }
  }

  /// 内容对应的那一份：没有就写好再改名进来，已有的不换（换了就是新文件，又要被检查）。
  private static func cached(_ text: String) throws -> URL {
    let hash = SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    let file = cache.appending(path: hash)
    if FileManager.default.isExecutableFile(atPath: file.path) { return file }
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    let pending = cache.appending(path: "\(hash).\(UUID().uuidString)")
    try Data(text.utf8).write(to: pending)
    chmod(pending.path, 0o755)
    // 同时有别的用例写好了同一份：留它的
    if renamex_np(pending.path, file.path, UInt32(RENAME_EXCL)) != 0 { try? FileManager.default.removeItem(at: pending) }
    return file
  }
}
