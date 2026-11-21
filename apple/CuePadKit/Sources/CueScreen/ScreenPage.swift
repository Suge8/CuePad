#if os(macOS)
/// `ScreenServer` 的那张页：一块画布铺满，连 `/screen` 收 H.264 帧用 `VideoDecoder` 解出来画上去，指针与滚轮按屏的宽高归一送回去，按键按 USB HID 的用法码送。
/// 看不见时（预览收起了、切到后台）断开，服务那头就不再编码；断了每秒重连，连上先来一个关键帧。
/// 底是黑的：画面按比例摆进去后四周多出来的那一圈读作屏的黑边。
public enum ScreenPage {
  /// `phone`：竖长的屏请活预览用手机宽那一档摆（`cuepad-viewport`，App 的 `LivePreview` 读它），画面正好填满那块屏，不在宽屏上两边留白。
  public static func html(title: String, phone: Bool) -> String {
    let escaped = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    return template.replacingOccurrences(of: "{title}", with: escaped).replacingOccurrences(of: "{viewport}", with: phone ? #"<meta name="cuepad-viewport" content="phone">"# : "")
  }

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
    body { box-sizing: border-box; padding-bottom: env(safe-area-inset-bottom); }
    canvas { display: block; width: 100%; height: 100%; object-fit: contain; outline: none; touch-action: none; user-select: none; -webkit-user-select: none; -webkit-touch-callout: none; }
    </style>
    </head>
    <body>
    <canvas tabindex="0"></canvas>
    <script>
    const canvas = document.querySelector("canvas"), context = canvas.getContext("2d");
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
        setTimeout(connect, 1000);
      };
    };
    document.addEventListener("visibilitychange", () => document.hidden ? socket?.close() : connect());
    connect();

    const say = message => socket?.readyState === WebSocket.OPEN && socket.send(JSON.stringify(message));
    // 画布按比例摆在页面里（object-fit: contain），四周可能留白：落在画面外的不算
    const place = event => {
      const box = canvas.getBoundingClientRect(), scale = Math.min(box.width / canvas.width, box.height / canvas.height);
      const width = canvas.width * scale, height = canvas.height * scale;
      return { x: (event.clientX - box.left - (box.width - width) / 2) / width, y: (event.clientY - box.top - (box.height - height) / 2) / height, width, height };
    };
    const inside = ({ x, y }) => x >= 0 && x <= 1 && y >= 0 && y <= 1;
    const clamp = value => Math.min(1, Math.max(0, value));
    let finger = null;
    canvas.onpointerdown = event => {
      const at = place(event);
      if (finger !== null || event.button || !inside(at)) return;
      finger = event.pointerId;
      canvas.setPointerCapture(finger);
      canvas.focus();
      say({ t: "down", x: at.x, y: at.y });
    };
    canvas.onpointermove = event => {
      if (event.pointerId !== finger) return;
      const at = place(event);
      say({ t: "move", x: clamp(at.x), y: clamp(at.y) });
    };
    canvas.onpointerup = canvas.onpointercancel = event => {
      if (event.pointerId !== finger) return;
      finger = null;
      const at = place(event);
      say({ t: "up", x: clamp(at.x), y: clamp(at.y) });
    };
    canvas.addEventListener("wheel", event => {
      event.preventDefault();
      const at = place(event);
      if (inside(at)) say({ t: "wheel", x: at.x, y: at.y, dx: event.deltaX / at.width, dy: event.deltaY / at.height });
    }, { passive: false });
    canvas.oncontextmenu = event => event.preventDefault();

    // event.code（键位）→ USB HID 键盘页的用法码：送的是哪颗键，打出什么字由模拟器里的键盘布局定
    const usages = {
      Enter: 40, Escape: 41, Backspace: 42, Tab: 43, Space: 44, Minus: 45, Equal: 46, BracketLeft: 47, BracketRight: 48, Backslash: 49, Semicolon: 51, Quote: 52,
      Backquote: 53, Comma: 54, Period: 55, Slash: 56, CapsLock: 57, ArrowRight: 79, ArrowLeft: 80, ArrowDown: 81, ArrowUp: 82,
      ControlLeft: 224, ShiftLeft: 225, AltLeft: 226, MetaLeft: 227, ControlRight: 228, ShiftRight: 229, AltRight: 230, MetaRight: 231,
    };
    for (let index = 0; index < 26; index++) usages["Key" + String.fromCharCode(65 + index)] = 4 + index;
    for (let digit = 1; digit <= 10; digit++) usages["Digit" + digit % 10] = 29 + digit;
    const held = new Set();
    const key = (event, down) => {
      const usage = usages[event.code];
      if (!usage || event.repeat) return;
      // 带 ⌘ 的留给 CuePad 自己的快捷键，也照样送进去
      if (!event.metaKey) event.preventDefault();
      down ? held.add(usage) : held.delete(usage);
      say({ t: "key", u: usage, d: down });
    };
    canvas.onkeydown = event => key(event, true);
    canvas.onkeyup = event => key(event, false);
    // 按着键时焦点走了，抬起那一下收不到：这里补上，不然模拟器里那颗键一直按着
    canvas.onblur = () => {
      held.forEach(usage => say({ t: "key", u: usage, d: false }));
      held.clear();
    };
    </script>
    </body>
    </html>
    """#
}
#endif
