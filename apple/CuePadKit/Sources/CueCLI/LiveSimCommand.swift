#if os(macOS)
import CueScreen
import CueStore
import Foundation

extension Command {
  static let liveSim = Command(
    path: ["live", "sim"], summary: "把一台开着的 iOS 模拟器开进活预览：用户在 CuePad 里看它的屏、直接点它（Mac、手机、iPad 上都行）", arguments: "[设备]",
    notes: """
      什么时候用：你在做 iOS 应用、已经把它装进模拟器跑起来，要用户看、上手试时。画面是活的，重新构建、重装应用不用再发；模拟器关了预览就停，再开起来重跑这一条。
      设备：UDID 或名字（iPhone 17）；不给就用开着的那一台，开着几台时报错列出来。
      之后同 cuepad live：开在这个会话旁边，竖长的屏摆成手机宽那一档。你自己要看画面用 cuepad live screenshot；snapshot、click、fill 认的是网页元素，这一页只有一块画布，点不到模拟器里的东西。
      用户能做的：点、拖、滚（滚轮与触控板变成手指拖动）、从屏的最下沿往上划回主屏幕；Mac 上点一下画面后直接用键盘打字，手机上点模拟器里的软键盘。横屏的画面是侧着的。
      \(Schema.output(LiveOutput.fields.description("Live"), "found 恒为 false"))
      """
  ) { call in
    let session = try agentSession(call, "live sim 只能在 Agent 执行的命令里运行，预览开在那个会话旁边")
    guard call.args.positionals.count <= 1 else { throw CLIError.usage("最多一台设备（给了 \(call.args.positionals.count) 个）") }
    let booted = try SimScreen.booted()
    let listed = booted.map { "\($0.name)（\($0.udid)）" }.joined(separator: "、")
    let device: SimScreen.Device
    if let wanted = call.args.positionals.first {
      guard let match = booted.first(where: { $0.udid.caseInsensitiveCompare(wanted) == .orderedSame || $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) else {
        throw CLIError.invalid("没有开着的模拟器叫「\(wanted)」。" + (booted.isEmpty ? "一台都没开：先把它开起来、装好应用" : "开着的：\(listed)"))
      }
      device = match
    } else {
      guard let only = booted.first else { throw CLIError.invalid("没有开着的模拟器：先把它开起来、装好应用，再运行 cuepad live sim") }
      guard booted.count == 1 else { throw CLIError.invalid("开着 \(booted.count) 台模拟器，说要哪一台：cuepad live sim <UDID 或名字>。开着的：\(listed)") }
      device = only
    }
    guard call.store.appIsOpen else { throw notOpen(call, "没有交出去。请用户打开 CuePad 后再运行 cuepad live sim") }
    let url = URL(string: "http://localhost:\(try await SimServe.ensure(device))")!
    try await call.store.sendLive(url, to: session, found: false)
    let text = "已把模拟器「\(device.name)」的屏交给这台 Mac 上的 CuePad：\(LiveAddress.shown(url))。会话开在主区、右半空着时预览直接滑开；否则会话栏头的预览钮亮起，等用户点开。重新构建、重装应用不用再发。"
    return Reply(text: text, json: LiveOutput.fields.json(LiveOutput(session: session, url: url.absoluteString, found: false)))
  }
}

/// 一台模拟器一个后台进程（`cuepad __screen <UDID> <端口>`）：把它的屏变成本机网页（`ScreenServer`），一直到模拟器关掉。
/// 另起进程、不放在 App 里：读屏与送手指用的是没公开的接口（`SimScreen`），它出事不带倒 App；也不跟着起它的那条命令退。
enum SimServe {
  static let entry = "__screen"

  /// 这台的服务在哪个口上：已经起着就用它，没有就起一个、等它听上。
  /// 口按 UDID 定：模拟器重开、服务重起后还是同一个地址，用户那头的预览自己接回来。被别的东西占着就顺次往后挪。
  static func ensure(_ device: SimScreen.Device) async throws -> UInt16 {
    let first = UInt16(47_600 + device.udid.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 300 })
    for port in first..<first + 8 {
      if await ScreenServer.serves(device.udid, port: port) { return port }
      let log = FileManager.default.temporaryDirectory.appending(path: "cuepad-screen-\(device.udid).log")
      try launch([entry, device.udid, String(port)], log: log)
      for _ in 0..<50 {
        try await Task.sleep(for: .milliseconds(100))
        if await ScreenServer.serves(device.udid, port: port) { return port }
        // 口被别的占着：它退出时在日志里写了这个词（`run`）
        let said = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        if said.contains(taken) { break }
        if !said.isEmpty { throw CLIError.invalid("接不上模拟器「\(device.name)」的屏：\(said.trimmingCharacters(in: .whitespacesAndNewlines))") }
      }
    }
    throw CLIError.invalid("接不上模拟器「\(device.name)」的屏：服务没起来（\(first)–\(first + 7) 这几个口都没听上）")
  }

  private static let taken = "port taken"

  /// 自成一个会话组、不接终端：起它的命令结束、Agent 收掉那条命令的进程组，它都留着。出错写进 `log`（先清空），`ensure` 读了报给 Agent。
  private static func launch(_ arguments: [String], log: URL) throws {
    guard let executable = Bundle.main.executablePath else { throw CLIError.invalid("找不到 cuepad 自己的路径") }
    FileManager.default.createFile(atPath: log.path, contents: nil)
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, log.path, O_WRONLY | O_TRUNC, 0)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
    var argv = ([executable] + arguments).map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let status = posix_spawn(&pid, executable, &actions, &attributes, &argv, environ)
    guard status == 0 else { throw CLIError.invalid("起不了模拟器屏的服务：\(String(cString: strerror(status)))") }
  }

  /// 后台进程的全部：听上、守着，模拟器关了或 cuepad 自己被换掉（App 更新）就退。不返回。
  static func run(_ arguments: [String]) async -> Never {
    func fail(_ message: String) -> Never {
      FileHandle.standardError.write(Data((message + "\n").utf8))
      exit(1)
    }
    guard arguments.count == 2, let port = UInt16(arguments[1]) else { fail("用法：cuepad \(entry) <UDID> <端口>") }
    do {
      let screen = try SimScreen(udid: arguments[0])
      let server = try ScreenServer(source: screen, port: port, identity: screen.device.udid, page: ScreenPage.html(title: screen.device.name, phone: screen.tall))
      do { try await server.start() } catch { fail("\(taken)：\(error)") }
      let executable = Bundle.main.executablePath ?? ""
      let born = try? FileManager.default.attributesOfItem(atPath: executable)[.systemFileNumber] as? Int
      while screen.isBooted, (try? FileManager.default.attributesOfItem(atPath: executable)[.systemFileNumber] as? Int) == born {
        try? await Task.sleep(for: .seconds(2))
      }
      _ = server
      exit(0)
    } catch {
      fail("\(error)")
    }
  }
}
#endif
