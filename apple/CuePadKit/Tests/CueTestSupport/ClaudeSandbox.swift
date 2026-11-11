#if os(macOS)
import Foundation

/// 隔离起真 Claude Code（钉住的版本）：配置目录、HOME、XDG 目录都在 `root` 里，模型是本进程的假模型（`FakeModel`，经 `ANTHROPIC_BASE_URL`），
/// 登录是假密钥、不带订阅令牌，辅助流量关掉，零网络；绝不碰 ~/.claude。Kit 的测试台与 App 的流程测试共用这一份。
public enum ClaudeSandbox {
  public static let apiKey = "sk-ant-api03-cuepad-test-key-not-real-00000000"
  public static let model = "haiku"

  /// 起 Claude Code 用的环境（目录在这里建好）。
  /// 模型地址只管 /v1/messages：fast mode 检查、WebFetch 的安全检查等不经它，所以关掉非必要流量，再清掉订阅登录、别的认证通道与代理。
  public static func environment(model fake: FakeModel, root: URL, signedIn: Bool = true) -> [String: String] {
    for name in ["config", "home", "xdg-data", "xdg-state", "xdg-cache", "xdg-config"] {
      try? FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
    }
    return [
      "CLAUDE_CONFIG_DIR": root.appending(path: "config").path, "HOME": root.appending(path: "home").path,
      "XDG_DATA_HOME": root.appending(path: "xdg-data").path, "XDG_STATE_HOME": root.appending(path: "xdg-state").path,
      "XDG_CACHE_HOME": root.appending(path: "xdg-cache").path, "XDG_CONFIG_HOME": root.appending(path: "xdg-config").path,
      "ANTHROPIC_BASE_URL": fake.baseURL, "ANTHROPIC_API_KEY": signedIn ? apiKey : "",
      "CLAUDE_CODE_OAUTH_TOKEN": "", "ANTHROPIC_AUTH_TOKEN": "", "CLAUDE_CODE_USE_BEDROCK": "", "CLAUDE_CODE_USE_VERTEX": "", "CLAUDE_CODE_USE_FOUNDRY": "",
      "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1",
      // 关了非必要流量，终端里的它照样去 downloads.claude.ai 装官方插件市场（2.1.318 经记录 CONNECT 的本机代理实测，每个进程一次）
      "CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL": "1",
      "HTTP_PROXY": "", "HTTPS_PROXY": "", "ALL_PROXY": "", "http_proxy": "", "https_proxy": "", "all_proxy": "",
      "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost",
      // 不要自动记忆：叫它"记住"什么时它会先去翻记忆文件、要用 Bash，等你确认
      "ANTHROPIC_MODEL": model, "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
    ]
  }

  /// 在配置目录写好 `.claude.json`：跳过首次启动的引导、"信任这个目录"（`work` 要是真实路径）与"用这个密钥吗"的询问。
  public static func seed(config: URL, trusting work: URL) throws {
    let seed: [String: Any] = [
      "hasCompletedOnboarding": true, "bypassPermissionsModeAccepted": true, "projects": [work.path: ["hasTrustDialogAccepted": true]],
      "customApiKeyResponses": ["approved": [String(apiKey.suffix(20))], "rejected": [String]()],
    ]
    try JSONSerialization.data(withJSONObject: seed).write(to: config.appending(path: ".claude.json"))
  }
}
#endif
