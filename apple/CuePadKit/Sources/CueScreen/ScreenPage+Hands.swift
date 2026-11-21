#if os(macOS)
extension ScreenPage {
  /// 手指、鼠标与键盘。
  static let hands = #"""
    // 按着的那根指头（或鼠标左键）。`gesture`：桌面窗口上的手指先不算按下，看它接下来是点、是滚、还是按住。
    // `pinch`：桌面窗口上落了第二根手指，这两根是在摆画面（`view`），不送进去
    let finger = null, gesture = null, pinch = null, zoomedFor = null;
    const held = new Set(), touches = new Map(), deepest = 6;
    const release = () => {
      clearTimeout(gesture?.hold);
      finger = gesture = null;
      held.clear();
    };
    const span = () => {
      const [a, b] = [...touches.values()];
      return { length: Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY), x: (a.clientX + b.clientX) / 2, y: (a.clientY + b.clientY) / 2 };
    };
    // 不让按下去的那一下把焦点带到画面上那一层的输入框里
    stage.onmousedown = event => event.preventDefault();
    // 听在窗口上：捏画面的两根手指常落在画面外的黑边上（手机上整幅摆进去时黑边占大半屏）
    addEventListener("pointerdown", event => {
      if (event.pointerType === "touch") touches.set(event.pointerId, event);
      if (desktop && touches.size === 2) {
        // 第一根开的头作废：按住拖已经按下去的补一个抬起
        if (gesture?.mode === "drag") say({ t: "up", ...point(gesture.at) });
        clearTimeout(gesture?.hold);
        finger = gesture = null;
        return pinch = { ...span(), view: { ...view } };
      }
      const at = place(event);
      // ⌃ 点是右键：那一下由 contextmenu 送
      if (finger !== null || pinch || event.button || (desktop && event.ctrlKey) || !stage.contains(event.target) || !inside(at)) return;
      finger = event.pointerId;
      if (desktop && event.pointerType === "touch") {
        const mine = gesture = { at, x: event.clientX, y: event.clientY, target: event.target, hold: setTimeout(() => { mine.mode = "drag"; say({ t: "down", ...point(at) }); }, 350) };
        return;
      }
      board.focus({ preventScroll: true });
      say({ t: "down", ...point(at) });
    });
    // 拖出画面、拖到页面外也跟着：听在窗口上，不用指针捕获（捕获了，点击就不落在按下的那个元素上，Agent 那一下点没点中认不出来）
    addEventListener("pointermove", event => {
      if (touches.has(event.pointerId)) touches.set(event.pointerId, event);
      if (pinch) {
        if (touches.size < 2) return;
        const now = span(), raw = pinch.view.zoom * now.length / pinch.length;
        // 过了头的那一段带阻力，松手弹回
        const zoom = raw < 1 ? 1 - (1 - raw) * 0.4 : raw > deepest ? deepest + (raw - deepest) * 0.25 : raw;
        // 两指正中的那一点跟着手走
        Object.assign(view, { zoom, x: now.x - (pinch.x - pinch.view.x) * zoom / pinch.view.zoom, y: now.y - (pinch.y - pinch.view.y) * zoom / pinch.view.zoom });
        zoomedFor = null;
        return settle();
      }
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
    });
    const lift = event => {
      touches.delete(event.pointerId);
      if (pinch) {
        if (touches.size) return;
        pinch = null;
        view.zoom = Math.min(deepest, Math.max(1, view.zoom));
        return settle(true);
      }
      if (event.pointerId !== finger) return;
      const was = gesture;
      finger = gesture = null;
      if (!was || was.mode === "drag") return say({ t: "up", ...point(place(event)) });
      clearTimeout(was.hold);
      if (was.mode === "scroll") return glide(was);
      if (event.type === "pointercancel") return;
      say({ t: "down", ...point(was.at) });
      say({ t: "up", ...point(was.at) });
      tapped = was.target;
    };
    // 手指点在输入框上：键盘跟着出来，画面凑到那个框上。键盘只在系统认的那一下点击里叫得出来（手指抬起那一下里叫，iOS 的网页视图不给），所以等它补发的 click
    let tapped = null;
    stage.onclick = event => {
      if (event.isTrusted && tapped?.matches?.("section input:not([readonly]), section textarea")) attend(tapped);
      tapped = null;
    };
    addEventListener("pointerup", lift);
    addEventListener("pointercancel", lift);
    // 松手后顺着刚才的速度再滑一段，下一根手指落下就停
    const glide = ({ at, speed }) => {
      speed = { dx: speed.dx * 0.95, dy: speed.dy * 0.95 };
      if (finger !== null || pinch || Math.hypot(speed.dx, speed.dy) < 0.0005) return;
      say({ t: "wheel", ...point(at), ...speed });
      requestAnimationFrame(() => glide({ at, speed }));
    };
    stage.addEventListener("wheel", event => {
      event.preventDefault();
      const at = place(event);
      if (inside(at)) say({ t: "wheel", x: at.x, y: at.y, dx: event.deltaX / at.width, dy: event.deltaY / at.height });
    }, { passive: false });
    stage.oncontextmenu = event => {
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
    board.addEventListener("blur", () => {
      held.forEach(usage => say({ t: "key", u: usage, d: false }));
      held.clear();
    });

    // 一段字：一条消息不带太长，服务那头一帧只收几 KB。`first` 是头一条（`fill` 用它带上换哪个框）
    const type = (text, first = { t: "text" }) => {
      const points = Array.from(text.replace(/\r\n?/g, "\n"));
      for (let index = 0; index < points.length || index === 0 && first.t !== "text"; index += 400) say({ ...(index ? { t: "text" } : first), s: points.slice(index, index + 400).join("") });
    };
    let attend = () => {};
    if (desktop) {
      let composing = false;
      const flush = () => {
        const text = field.value;
        field.value = "";
        type(text);
      };
      field.oninput = () => composing || flush();
      field.addEventListener("compositionstart", () => { composing = true; field.classList.add("composing"); });
      field.addEventListener("compositionend", () => { composing = false; field.classList.remove("composing"); flush(); });

      // 手机：点了输入框（`attend`）或按键盘钮，键盘出来；画面凑到那个框上（字看得清、框在键盘上面），键盘收了放回原样。
      // 中途自己捏过画面（`zoomedFor` 清掉了）就不再替他摆
      const keys = document.querySelector("#keys"), whole = document.querySelector("#whole"), hint = document.querySelector("p");
      let before = null;
      const frame = target => {
        const { width, height } = room(), box = target.getBoundingClientRect();
        // 应用里的一点放到这头的 1.4 点：Mac 上 13 点的字到了手机正文那么大
        const zoom = Math.min(deepest, Math.max(view.zoom, 1.4 * points / parseFloat(stage.style.width))), grow = zoom / view.zoom;
        const left = (box.left - view.x) * grow, top = (box.top - view.y) * grow;
        Object.assign(view, { zoom, x: box.width * grow > width - 32 ? 16 - left : (width - box.width * grow) / 2 - left, y: height * 0.4 - top - box.height * grow / 2 });
        settle(true);
      };
      attend = target => {
        before ??= { ...view };
        zoomedFor = target;
        field.focus({ preventScroll: true });
        frame(target);
      };
      field.addEventListener("focus", () => keys.classList.add("on"));
      field.addEventListener("blur", () => {
        keys.classList.remove("on");
        if (before && zoomedFor) { Object.assign(view, before); settle(true); }
        before = zoomedFor = null;
      });
      for (const button of [keys, whole]) button.onpointerdown = event => event.preventDefault();
      keys.onclick = () => document.activeElement === field ? field.blur() : field.focus({ preventScroll: true });
      whole.onclick = () => { view.zoom = 1; before = zoomedFor = null; settle(true); };
      // 键盘弹出来：页面缩到键盘上面那一块，钮都还看得见；画面留在原来的大小，只挪进看得见的那一块
      window.visualViewport?.addEventListener("resize", () => {
        document.body.style.height = visualViewport.height + "px";
        scrollTo(0, 0);
        zoomedFor?.isConnected ? frame(zoomedFor) : settle(true);
      });
      // 头一回在手机上看到缩得很小的窗口：说一声可以放大
      if (matchMedia("(pointer: coarse)").matches && !localStorage.hinted) {
        hint.textContent = navigator.language.startsWith("zh") ? "双指张开放大" : "Pinch to zoom";
        setTimeout(() => { hint.style.opacity = 1; }, 600);
        const hide = () => { hint.style.opacity = 0; localStorage.hinted = 1; };
        setTimeout(hide, 4200);
        addEventListener("pointerdown", hide, { once: true });
      }
    }
    """#
}
#endif
