#if os(macOS)
import Foundation

/// 真 Claude Code 的用例（Kit 的 `ClaudeTestbed`、App 的 Cue 评测）用的登录：Claude Code 自己存在钥匙串里的那条
/// （它自己也经 `security` 读写，读时不弹授权框），不读别家（Pi）的凭据，也不要人动手。只取访问令牌交给隔离测试台起的进程
/// （`CLAUDE_CODE_OAUTH_TOKEN`），不落盘、不进录像带；不在这里刷新：refresh token 只能用一次，测试先刷新就把用户的登录挤掉了，
/// 过期了等 Claude Code 下次用时自己续。
public enum ClaudeLogin {
  /// 打印此刻访问令牌的命令（外壳脚本里起 claude 时与 `token` 同用这一条）。
  public static let tokenCommand =
    "/usr/bin/security find-generic-password -s 'Claude Code-credentials' -w | /usr/bin/plutil -extract claudeAiOauth.accessToken raw -o - -"

  /// 此刻的访问令牌；这台 Mac 上的 Claude Code 没登录为 nil。
  public static var token: String? {
    let process = Process(), output = Pipe()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = ["-c", tokenCommand]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return process.terminationStatus == 0 && !token.isEmpty ? token : nil
  }
}
#endif
