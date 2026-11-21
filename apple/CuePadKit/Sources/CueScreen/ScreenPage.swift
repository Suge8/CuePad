#if os(macOS)
/// `ScreenServer` 的那张页：一块画布铺满，连 `/screen` 收 H.264 帧用 `VideoDecoder` 解出来画上去，指针、滚轮、键盘送回去（`ScreenInput`）。
/// 看不见时（预览收起了、切到后台）断开，服务那头就不再取画面；断了每秒重连，连上先来一个关键帧。
/// 底是黑的：画面按比例摆进去后四周多出来的那一圈读作屏的黑边。
public enum ScreenPage {
  public enum Kind: Sendable {
    /// 一块触摸屏（模拟器）：指针就是手指，键位原样送进去（打出什么字由它里面的键盘定）。
    /// `tall`：竖长的屏请活预览用手机宽那一档摆（`cuepad-viewport`，App 的 `LivePreview` 读它），画面正好填满，不在宽屏上两边留白。
    case touchscreen(tall: Bool)
    /// 桌面应用的窗口：指针是鼠标。字由看的这一头的输入法组好整段送，功能键与带 ⌘ ⌃ 的照键位送；
    /// 手机上轻点是点一下、拖是滚、按住不动再拖是按着拖，右下角那颗钮叫出键盘。
    case desktop
  }

  public static func html(title: String, kind: Kind) -> String {
    let escaped = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    let (viewport, desktop) = switch kind {
    case .touchscreen(tall: true): (#"<meta name="cuepad-viewport" content="phone">"#, false)
    case .touchscreen: ("", false)
    case .desktop: ("", true)
    }
    return template.replacingOccurrences(of: "{title}", with: escaped).replacingOccurrences(of: "{viewport}", with: viewport)
      .replacingOccurrences(of: "{typing}", with: desktop ? typing : "").replacingOccurrences(of: "{desktop}", with: "\(desktop)")
  }

  /// 桌面那一种才有：收字的输入框（平时看不见，输入法组字时露出来）与手机上叫出键盘的钮。
  private static let typing = #"""
    <textarea autocapitalize="off" autocomplete="off" autocorrect="off" spellcheck="false"></textarea>
    <button aria-label="Keyboard"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><rect x="2.5" y="6" width="19" height="12" rx="2.5"/><path d="M6.5 10h.01M10 10h.01M13.5 10h.01M17 10h.01M8 14h8"/></svg></button>
    """#

  private static let template = #"""
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
    {viewport}
    <title>{title}</title>
    <style>
    html, body { margin: 0; height: 100%; overflow: hidden; overscroll-behavior: none; background: black; }
    /* 手机上让出主屏幕指示条那一截：从画面最下沿往上划是给模拟器的，不让系统当成回自己的主屏幕 */
    body { position: relative; box-sizing: border-box; padding-bottom: env(safe-area-inset-bottom); }
    canvas { display: block; width: 100%; height: 100%; object-fit: contain; outline: none; touch-action: none; user-select: none; -webkit-user-select: none; -webkit-touch-callout: none; }
    /* 字号不小于 16px：再小 iOS 聚焦时会把整页放大 */
    textarea { position: absolute; left: 50%; bottom: 12px; transform: translateX(-50%); width: 1px; height: 1px; padding: 0; border: 0; opacity: 0; resize: none; outline: none; font: 16px system-ui; white-space: nowrap; overflow: hidden; }
    textarea.composing { width: 12em; height: 1.5em; padding: 6px 12px; border-radius: 10px; opacity: 1; background: #1c1c1e; color: white; }
    button { display: none; position: absolute; right: 12px; bottom: calc(12px + env(safe-area-inset-bottom)); width: 44px; height: 44px; padding: 0; border: 0; border-radius: 22px; background: rgba(58, 58, 60, 0.9); color: white; place-items: center; }
    @media (pointer: coarse) { button { display: grid; } }
    </style>
    </head>
    <body>
    <canvas></canvas>
    {typing}
    <script>
    const desktop = {desktop};
    const canvas = document.querySelector("canvas"), context = canvas.getContext("2d");
    const field = document.querySelector("textarea"), board = field ?? canvas;
    if (!desktop) canvas.tabIndex = 0;
    let socket, decoder, configured = "";

    const paint = frame => {
      if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
        canvas.width = frame.displayWidth;
        canvas.height = frame.displayHeight;
      }
      context.drawImage(frame, 0, 0);
      frame.close();
    };

    const configure = text => {
      if (text === configured && decoder.state === "configured") return;
      const { codec, description } = JSON.parse(text);
      if (decoder && decoder.state !== "closed") decoder.close();
      decoder = new VideoDecoder({ output: paint, error: () => socket.close() });
      decoder.configure({ codec, description: Uint8Array.from(atob(description), c => c.charCodeAt(0)), optimizeForLatency: true });
      configured = text;
    };

    const say = message => socket?.readyState === WebSocket.OPEN && socket.send(JSON.stringify(message));
    // 画布按比例摆在页面里（object-fit: contain），四周可能留白：落在画面外的不算
    const place = event => {
      const box = canvas.getBoundingClientRect(), scale = Math.min(box.width / canvas.width, box.height / canvas.height);
      const width = canvas.width * scale, height = canvas.height * scale;
      return { x: (event.clientX - box.left - (box.width - width) / 2) / width, y: (event.clientY - box.top - (box.height - height) / 2) / height, width, height };
    };
    const inside = ({ x, y }) => x >= 0 && x <= 1 && y >= 0 && y <= 1;
    const clamp = value => Math.min(1, Math.max(0, value));
    const point = at => ({ x: clamp(at.x), y: clamp(at.y) });

    // 按着的那根指头（或鼠标左键）。`gesture`：桌面窗口上的手指先不算按下，看它接下来是点、是滚、还是按住
    let finger = null, gesture = null;
    const held = new Set();
    canvas.onmousedown = event => event.preventDefault();
    canvas.onpointerdown = event => {
      const at = place(event);
      // ⌃ 点是右键：那一下由 contextmenu 送
      if (finger !== null || event.button || (desktop && event.ctrlKey) || !inside(at)) return;
      finger = event.pointerId;
      canvas.setPointerCapture(finger);
      if (desktop && event.pointerType === "touch") {
        const mine = gesture = { at, x: event.clientX, y: event.clientY, hold: setTimeout(() => { mine.mode = "drag"; say({ t: "down", ...point(at) }); }, 350) };
        return;
      }
      board.focus({ preventScroll: true });
      say({ t: "down", ...point(at) });
    };
    canvas.onpointermove = event => {
      if (event.pointerId !== finger) return;
      const at = place(event);
      if (!gesture || gesture.mode === "drag") return say({ t: "move", ...point(at) });
      const dx = event.clientX - gesture.x, dy = event.clientY - gesture.y;
      if (!gesture.mode && Math.hypot(dx, dy) < 8) return;
      clearTimeout(gesture.hold);
      gesture.mode = "scroll";
      gesture.x = event.clientX;
      gesture.y = event.clientY;
      // 内容跟着手指走：手指往上，内容往下滚
      gesture.speed = { dx: -dx / at.width, dy: -dy / at.height };
      say({ t: "wheel", ...point(gesture.at), ...gesture.speed });
    };
    canvas.onpointerup = canvas.onpointercancel = event => {
      if (event.pointerId !== finger) return;
      const was = gesture;
      finger = gesture = null;
      if (!was || was.mode === "drag") return say({ t: "up", ...point(place(event)) });
      clearTimeout(was.hold);
      if (was.mode === "scroll") return glide(was);
      if (event.type === "pointercancel") return;
      say({ t: "down", ...point(was.at) });
      say({ t: "up", ...point(was.at) });
    };
    // 松手后顺着刚才的速度再滑一段，下一根手指落下就停
    const glide = ({ at, speed }) => {
      speed = { dx: speed.dx * 0.95, dy: speed.dy * 0.95 };
      if (finger !== null || Math.hypot(speed.dx, speed.dy) < 0.0005) return;
      say({ t: "wheel", ...point(at), ...speed });
      requestAnimationFrame(() => glide({ at, speed }));
    };
    canvas.addEventListener("wheel", event => {
      event.preventDefault();
      const at = place(event);
      if (inside(at)) say({ t: "wheel", x: at.x, y: at.y, dx: event.deltaX / at.width, dy: event.deltaY / at.height });
    }, { passive: false });
    canvas.oncontextmenu = event => {
      event.preventDefault();
      const at = place(event);
      if (desktop && inside(at)) say({ t: "menu", x: at.x, y: at.y });
    };

    // event.code（键位）→ USB HID 键盘页的用法码
    const usages = {
      Enter: 40, Escape: 41, Backspace: 42, Tab: 43, Space: 44, Minus: 45, Equal: 46, BracketLeft: 47, BracketRight: 48, Backslash: 49, Semicolon: 51, Quote: 52,
      Backquote: 53, Comma: 54, Period: 55, Slash: 56, CapsLock: 57, Home: 74, PageUp: 75, Delete: 76, End: 77, PageDown: 78, ArrowRight: 79, ArrowLeft: 80, ArrowDown: 81, ArrowUp: 82,
      ControlLeft: 224, ShiftLeft: 225, AltLeft: 226, MetaLeft: 227, ControlRight: 228, ShiftRight: 229, AltRight: 230, MetaRight: 231,
    };
    for (let index = 0; index < 26; index++) usages["Key" + String.fromCharCode(65 + index)] = 4 + index;
    for (let digit = 1; digit <= 10; digit++) usages["Digit" + digit % 10] = 29 + digit;
    for (let index = 1; index <= 12; index++) usages["F" + index] = 57 + index;
    // 桌面窗口：打得出字的键不照键位送，字由输入法组好后整段送（`flush`）；⌘V 贴进来的也是字
    const typed = event => desktop && usages[event.code] < 224 && event.key.length === 1 && !event.ctrlKey && (!event.metaKey || event.code === "KeyV");
    const key = (event, down) => {
      const usage = usages[event.code];
      // 触摸屏按着不放由它自己连发；桌面窗口照这头的连发送
      if (!usage || event.isComposing || event.keyCode === 229 || typed(event) || (event.repeat && !desktop)) return;
      // 触摸屏的页带 ⌘ 的留给 CuePad 自己的快捷键，也照样送进去
      if (desktop ? usage < 224 : !event.metaKey) event.preventDefault();
      down ? held.add(usage) : held.delete(usage);
      say({ t: "key", u: usage, d: down });
    };
    board.onkeydown = event => key(event, true);
    board.onkeyup = event => key(event, false);
    // 按着键时焦点走了，抬起那一下收不到：这里补上，不然那颗键一直按着
    board.onblur = () => {
      held.forEach(usage => say({ t: "key", u: usage, d: false }));
      held.clear();
    };

    if (desktop) {
      let composing = false;
      // 一条消息不带太长的字：服务那头一帧只收几 KB
      const flush = () => {
        const points = Array.from(field.value.replace(/\r\n?/g, "\n"));
        field.value = "";
        for (let index = 0; index < points.length; index += 400) say({ t: "text", s: points.slice(index, index + 400).join("") });
      };
      field.oninput = () => composing || flush();
      field.addEventListener("compositionstart", () => { composing = true; field.classList.add("composing"); });
      field.addEventListener("compositionend", () => { composing = false; field.classList.remove("composing"); flush(); });
      const button = document.querySelector("button");
      button.onpointerdown = event => event.preventDefault();
      button.onclick = () => document.activeElement === field ? field.blur() : field.focus({ preventScroll: true });
      // 手机的键盘弹出来：页面缩到键盘上面那一块，画面与钮都还看得见
      window.visualViewport?.addEventListener("resize", () => {
        document.body.style.height = visualViewport.height + "px";
        scrollTo(0, 0);
      });
    }

    const connect = () => {
      if (document.hidden || socket) return;
      const mine = socket = new WebSocket(`ws://${location.host}/screen`);
      mine.binaryType = "arraybuffer";
      mine.onmessage = ({ data }) => {
        if (typeof data === "string") return configure(data);
        const bytes = new Uint8Array(data);
        decoder.decode(new EncodedVideoChunk({ type: bytes[0] ? "key" : "delta", timestamp: performance.now() * 1000, data: bytes.subarray(1) }));
      };
      mine.onclose = () => {
        if (socket === mine) socket = null;
        // 按着的手指与键服务那头替这条连接抬起了：这头也忘掉，重连后不接着发半截的拖动
        clearTimeout(gesture?.hold);
        finger = gesture = null;
        held.clear();
        setTimeout(connect, 1000);
      };
    };
    document.addEventListener("visibilitychange", () => document.hidden ? socket?.close() : connect());
    connect();
    </script>
    </body>
    </html>
    """#
}
#endif
