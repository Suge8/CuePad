# design/promo 物料产线索引

宣传物料与可重跑产线。所有截图基于隔离演示库，不碰真实用户数据。

## 产品文案定稿（对外描述的单一事实源）

- **GitHub 仓库 description**：
  `📝 Prompt Scratchpad for Coding Agents - Write Comfortably, Dispatch in One Tap | 给 Vibe Coding 的提示词灵感本，写好一键直达终端`
- **中文标语**：提示词写好，一键投送 · 副题：给 coding agents 设计的 macOS 草稿本 · 写好直达终端与编辑器
- **英文标语**：Write your prompt, dispatch in one tap · 副题：A macOS scratchpad for coding agents · straight to your terminal and editor
- hero / social 图的中英文案以此为准；英文图用 `?lang=en` 出（见下表）

| 路径 | 说明 |
| --- | --- |
| `demo-data.sql` + `make-demo-db.sh` | 演示数据事实源；生成 `/tmp/cuepad-promo` 隔离库并给出启动命令（`--user-data-dir` + `--remote-debugging-port=9444`） |
| `shots/scene.mjs` | CDP 场景驱动（node 跑，bun 的 WebSocket 与 playwright 不兼容）：welcome-close / project / editor / variables / search / tasks / theme / neutral |
| `shots/raw/` | 原始窗口截图（`screencapture -o -l <windowID>`，2400×1520 @2x） |
| `shots/final/` | 加框成图（圆角 + 阴影 + 米白画布），README 折叠截图用 |
| `compose/` | HTML 合成模板 + `compose.mjs`（headless Chromium 精确画布出图；`auto` 尺寸按 body 截）；hero/social 模板支持 `?lang=en` 出英文版（`*-en-*.png`，英文 README 与国际受众用） |
| `visual/` | 成图：README hero、GitHub social preview、抠图素材（`design/tools/cutout.swift` 产物） |
| `motion/record-ui.mjs` | 演示 GIF 段1：CDP screencast 直录 renderer（不受桌面 Space/遮挡影响；系统级录屏在多 agent 机器上不可控，勿走回头路） |
| `motion/terminal.tape` | 演示 GIF 段2：VHS 渲染终端收到投送（zle widget 绑 Ctrl+P 模拟多行 bracketed paste；vhs 的 Copy 不解释 `\n`） |
| `motion/make-gif.sh` | 两段拼接 → `demo-dispatch.gif`（960 宽 12fps 两趟调色板） |

重跑全流程：`make-demo-db.sh` → 启动 app → `scene.mjs` 置状态 + 截图 → `compose.mjs` 出图 → `record-ui.mjs` + `vhs terminal.tape` + `make-gif.sh`。

注意：录 GIF 段1 会触发一次真实投送（写剪贴板 + 激活目标应用），录前用 localStorage `cuepad:dispatch-target` 固定目标到「终端」，避免投送目标漂移到别的前台应用。
