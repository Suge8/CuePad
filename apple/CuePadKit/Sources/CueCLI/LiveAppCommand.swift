#if os(macOS)
import CueScreen
import CueStore
import Foundation
import Security

extension Command {
  static let liveApp = Command(
    path: ["live", "app"], summary: "把一个 Mac 应用起进活预览：用户在 CuePad 里看它的窗口、直接点它（Mac、手机、iPad 上都行）", arguments: "<应用.app> [-- 启动参数…]",
    notes: """
      什么时候用：你在做 Mac 的原生应用（AppKit、SwiftUI、Catalyst），调试构建好了，要用户看、上手试时。这一条在后台起一份新的实例（不抢前台），它的窗口就是预览里的那一页。
      重新构建后再跑一遍这一条：上一次起的那份它替你退掉、起新的，用户那头的预览自己接上。
      画面是这个应用最前面的那扇主窗口，连同它的表单、弹层、菜单；新开一扇窗（设置）画面换过去，关了换回来。窗口被挡着、在别的桌面都照常出画面；最小化、隐藏时没有。
      用户能做的：点、拖、滚、右键，键盘打字（用他那一头的输入法）与快捷键；手机上轻点是点、拖是滚、按住再拖是拖，右下角的钮叫出键盘。拖标题栏挪窗口、拖边缘改大小、指针悬停的效果做不到。
      之后同 cuepad live。你自己要看画面用 cuepad live screenshot；snapshot、click、fill 认的是网页元素，这一页只有一块画布，点不到应用里的东西。
      起不进去的：开了 Hardened Runtime 的构建（Xcode 的 Debug 构建默认不开，发布构建、装好的成品都开着）。网页壳的应用（Electron、Tauri）不用这一条，对它的开发服务用 cuepad live。
      应用得由你自己的脚本起时（调试器、带环境的启动脚本）：起它的环境里加上 DYLD_INSERT_LIBRARIES=\(AppServe.library) 与 CUEPAD_SCREEN_PORT=<端口>，起来后 cuepad live <端口>。
      \(Schema.output(LiveOutput.fields.description("Live"), "found 恒为 false"))
      """
  ) { call in
    let session = try agentSession(call, "live app 只能在 Agent 执行的命令里运行，预览开在那个会话旁边")
    guard let path = call.args.positionals.first else { throw CLIError.usage("需要 <应用.app>") }
    let app = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: call.directory, isDirectory: true)).standardizedFileURL
    guard let bundle = Bundle(url: app), let executable = bundle.executableURL else { throw CLIError.invalid("「\(path)」不是一个 Mac 应用（.app）") }
    let name = app.deletingPathExtension().lastPathComponent
    guard !AppServe.refusesLibraries(app) else {
      throw CLIError.invalid("「\(name)」开了 Hardened Runtime（或是系统自带的应用），载不进取画面的库：用你自己的调试构建（Xcode 的 Debug 默认不开；构建脚本里是 ENABLE_HARDENED_RUNTIME=NO）")
    }
    guard call.store.appIsOpen else { throw notOpen(call, "没有起。请用户打开 CuePad 后再运行 cuepad live app") }
    let (port, pid) = try await AppServe.launch(app, executable: executable, arguments: Array(call.args.positionals.dropFirst()))
    let url = URL(string: "http://localhost:\(port)")!
    try await call.store.sendLive(url, to: session, found: false)
    let text = "已起「\(name)」（进程 \(pid)），它的窗口交给了这台 Mac 上的 CuePad：\(LiveAddress.shown(url))。会话开在主区、右半空着时预览直接滑开；否则会话栏头的预览钮亮起，等用户点开。重新构建后再运行这一条，这一份会被退掉换成新的。\n"
    return Reply(text: text, json: LiveOutput.fields.json(LiveOutput(session: session, url: url.absoluteString, found: false)))
  }
}

/// 把一个 Mac 应用连同取画面的库（`CueScreenHost`，在 CuePad.app 的 Frameworks 里）一起起来：库在应用自己的进程里起屏的服务。
enum AppServe {
  static let library = URL(fileURLWithPath: Bundle.main.executablePath ?? "").resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Frameworks/CueScreenHost.dylib").path

  /// 开了 Hardened Runtime 的进程里 dyld 不理 `DYLD_INSERT_LIBRARIES`，也不载别家签名的库（两项豁免都声明了的除外）；系统自带的应用一律不理。
  static func refusesLibraries(_ app: URL) -> Bool {
    var code: SecStaticCode?
    var copied: CFDictionary?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
          SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &copied) == errSecSuccess, let info = copied as? [CFString: Any] else { return false }
    let hardened = ((info[kSecCodeInfoFlags] as? NSNumber)?.uint32Value ?? 0) & SecCodeSignatureFlags.runtime.rawValue != 0
    let entitlements = info[kSecCodeInfoEntitlementsDict] as? [String: Any] ?? [:]
    let exempt = ["com.apple.security.cs.allow-dyld-environment-variables", "com.apple.security.cs.disable-library-validation"].allSatisfy { entitlements[$0] as? Bool == true }
    return hardened && !exempt || info[kSecCodeInfoPlatformIdentifier] as? Int ?? 0 != 0
  }

  /// 起一份新的实例，等它里面屏的服务听上。回来的是服务的口与实例的进程号。
  /// 口按应用的路径定：重新构建、再起之后还是同一个地址，用户那头的预览自己接回来。口上是上一次起的这个应用就先退掉它；被别的占着就顺次往后挪。
  static func launch(_ app: URL, executable: URL, arguments: [String]) async throws -> (port: UInt16, pid: pid_t) {
    let name = app.deletingPathExtension().lastPathComponent
    let first = UInt16(48_000 + app.path.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 300 })
    /// 这个口上屏的服务所在的进程，是这个应用的才算。
    func serving(_ port: UInt16) async -> pid_t? {
      guard let pid = await ScreenServer.identity(port: port).flatMap({ pid_t($0) }) else { return nil }
      var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
      let length = proc_pidpath(pid, &path, UInt32(path.count))
      guard length > 0 else { return nil }
      return URL(fileURLWithPath: String(decoding: path[..<Int(length)], as: UTF8.self)).resolvingSymlinksInPath() == executable.resolvingSymlinksInPath() ? pid : nil
    }
    for port in first..<first + 8 {
      if let old = await serving(port) {
        kill(old, SIGTERM)
        for _ in 0..<50 where kill(old, 0) == 0 { try await Task.sleep(for: .milliseconds(100)) }
        guard kill(old, 0) != 0 else { throw CLIError.invalid("上一次起的「\(name)」（进程 \(old)）退不掉：先结束它再运行") }
      }
      guard free(port) else { continue }
      // 经 LaunchServices 起（同在访达里双击）：不是这条命令的子进程，命令结束、Agent 收掉它的进程组，应用都留着
      let open = Process()
      open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
      open.arguments = ["-n", "-g", app.path, "--env", "DYLD_INSERT_LIBRARIES=\(library)", "--env", "CUEPAD_SCREEN_PORT=\(port)"] + (arguments.isEmpty ? [] : ["--args"] + arguments)
      let said = Pipe()
      open.standardError = said
      try open.run()
      let complaint = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      open.waitUntilExit()
      guard open.terminationStatus == 0 else { throw CLIError.invalid("起不了「\(name)」：\(complaint)") }
      for _ in 0..<200 {
        try await Task.sleep(for: .milliseconds(100))
        if let pid = await serving(port) { return (port, pid) }
      }
      throw CLIError.invalid("「\(name)」起了，但 20 秒里它的窗口没接上：它可能一启动就退了，或不是 AppKit 的应用（命令行程序、网页壳）")
    }
    throw CLIError.invalid("起不了「\(name)」的预览：\(first)–\(first + 7) 这几个口都被占着")
  }

  /// 这个口此刻没人在听。
  private static func free(_ port: UInt16) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(descriptor) }
    var reuse: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: port.bigEndian, sin_addr: in_addr(s_addr: INADDR_LOOPBACK.bigEndian), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
  }
}
#endif
