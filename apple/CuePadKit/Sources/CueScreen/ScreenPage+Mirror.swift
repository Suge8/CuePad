#if os(macOS)
extension ScreenPage {
  /// 画面上那一层看不见的元素（只有桌面窗口那一种）：照服务那头说的（`/outline`，`ScreenSource.outline`）一个元素摆一个、压在它在画面里的位置上。
  /// 画面本身只是一块画布，读页面的什么都读不到；有了这一层，Agent 的 snapshot、click、fill、press、wait 与用户的点选同对一张网页一样用：
  /// 它们点的是这一层的元素，落点正是画面里那个控件，按下去照常经 `hands` 送进应用。
  static let mirror = #"""
    const layer = stage.querySelector("section"), made = new Map();
    // 画面横着是应用里的多少点（`attend` 照它算放多大）。`app`：这一层照的是哪一份应用，换了一份（重新构建后再起的）整层重摆，旧的引用不落到新的元素上
    let points = 0, app = 0;
    // 自己接点击的（落点认它）；别的只供读，不挡着底下的
    const live = new Set(["window", "dialog", "menu", "button", "link", "textbox", "searchbox", "checkbox", "radio", "switch", "combobox", "slider", "spinbutton", "option", "tab", "menuitem"]);
    // 名字写成内容的：读页面的从内容取这几种的名字，等文字出现（wait --text）也找得到
    const named = new Set(["text", "button", "link", "checkbox", "radio", "switch", "option", "tab", "menuitem", "heading"]);
    const tag = node => node.r === "textbox" || node.r === "searchbox" ? (node.lines ? "textarea" : "input") : ["combobox", "slider", "spinbutton"].includes(node.r) ? "input" : "div";
    const set = (element, name, value) => value === undefined || value === false ? element.removeAttribute(name) : element.getAttribute(name) !== String(value) && element.setAttribute(name, value);
    const arrange = (nodes, parent, within, seen) => {
      nodes.forEach((node, index) => {
        let element = made.get(node.i);
        if (element?.localName !== tag(node)) {
          element?.remove();
          element = document.createElement(tag(node));
          element.dataset.i = node.i;
          made.set(node.i, element);
        }
        seen.add(node.i);
        // 后面的压在前面的上头：同服务那头给的次序（窗口从底下往上）
        if (parent.children[index] !== element) parent.insertBefore(element, parent.children[index] ?? null);
        const [x, y, width, height] = node.b, [left, top, outer, tall] = within;
        Object.assign(element.style, { left: (x - left) / outer * 100 + "%", top: (y - top) / tall * 100 + "%", width: width / outer * 100 + "%", height: height / tall * 100 + "%" });
        const typed = element.localName !== "div", text = !typed && !node.k && named.has(node.r);
        element.className = (live.has(node.r) ? "live" : "") + (node.modal ? " modal" : "");
        set(element, "role", node.r === "text" || node.r === "textbox" && typed ? undefined : node.r);
        set(element, "aria-label", text ? undefined : node.n);
        set(element, "aria-checked", node.on);
        set(element, "aria-disabled", node.off);
        set(element, "aria-selected", node.sel);
        set(element, "aria-expanded", node.open);
        // 给了它才能照引用聚焦（press <键> <ref>）；-1：Tab 不经过（输入框也是，不然真键盘的 Tab 会停进这一层看不见的框里）
        set(element, "tabindex", live.has(node.r) && !["window", "dialog", "menu"].includes(node.r) ? -1 : undefined);
        if (typed) {
          set(element, "type", node.secret ? "password" : node.r === "searchbox" ? "search" : undefined);
          set(element, "placeholder", node.hint);
          element.readOnly = !["textbox", "searchbox"].includes(node.r);
          if (!node.secret && element.value !== (node.v ?? "")) element.value = node.v ?? "";
        } else if (text) {
          if (element.textContent !== (node.n ?? "")) element.textContent = node.n ?? "";
        } else {
          for (const child of [...element.childNodes]) if (child.nodeType === Node.TEXT_NODE) child.remove();
          arrange(node.k ?? [], element, node.b, seen);
        }
        if (node.focus && typed && element !== zoomedFor && zoomedFor) attend(element);
      });
      while (parent.children.length > nodes.length) parent.lastElementChild.remove();
    };
    let asking = false, stale = false, asked = 0, timer = null;
    const ask = async () => {
      [asking, stale, asked] = [true, false, performance.now()];
      try {
        const response = await fetch("/outline");
        if (response.ok) {
          const seen = new Set(), outline = await response.json();
          points = outline.points;
          if (app !== outline.app) {
            layer.replaceChildren();
            made.clear();
            app = outline.app;
          }
          arrange(outline.nodes, layer, [0, 0, 1, 1], seen);
          for (const id of [...made.keys()]) if (!seen.has(id)) made.delete(id);
        }
      } catch {}
      asking = false;
      if (stale) look(true);
    };
    // 问着的时候又有新输入：答回来的可能是那之前的，接着再问一次。画面自己在动（动画）时一秒最多问一次
    look = now => {
      if (document.hidden) return;
      if (asking) return void (stale ||= now);
      const wait = now ? 0 : 1000 - (performance.now() - asked);
      if (wait <= 0) return clearTimeout(timer), timer = null, void ask();
      timer ??= setTimeout(() => { timer = null; look(true); }, wait);
    };

    // Agent 照元素做的那几样（CuePad 往页面里注入的脚本对着这一层的元素做，这里转给应用里的那个控件）：
    // 聚焦一个元素；把输入框填成一段字（它改完值发 change）；按键是脚本合成的（isTrusted 为假，真键盘的走 hands）。
    // change 也只认脚本发的那一下：它改过的框失焦时浏览器自己还会补发一次，照那一次再填一遍会把应用里后来的字盖回去
    // 对着一个元素按翻页键是滚它所在的那一块：应用在后台，列表拿不到键盘焦点，照键送进去滚不动
    layer.addEventListener("focusin", event => say({ t: "focus", i: +event.target.dataset.i }));
    layer.addEventListener("change", event => event.isTrusted || type(event.target.value, { t: "fill", i: +event.target.dataset.i }));
    const plain = { Enter: 40, Escape: 41, Backspace: 42, Tab: 43, Space: 44, " ": 44, Home: 74, PageUp: 75, Delete: 76, End: 77, PageDown: 78, ArrowRight: 79, ArrowLeft: 80, ArrowDown: 81, ArrowUp: 82 };
    for (const phase of ["keydown", "keyup"]) {
      document.addEventListener(phase, event => {
        if (event.isTrusted) return;
        scripted = phase === "keydown";
        const pages = { PageDown: 0.4, PageUp: -0.4 }[event.key];
        if (pages && layer.contains(event.target)) {
          const box = event.target.getBoundingClientRect();
          return phase === "keydown" && say({ t: "wheel", ...point(place({ clientX: box.left + box.width / 2, clientY: box.top + box.height / 2 })), dx: 0, dy: pages });
        }
        const usage = plain[event.key];
        if (usage) say({ t: "key", u: usage, d: phase === "keydown" });
        else if (phase === "keydown" && event.key.length === 1) say({ t: "text", s: event.key });
      }, true);
    }
    """#
}
#endif
