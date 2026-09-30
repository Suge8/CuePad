# design/promo 物料索引

宣传物料的合成模板与成图。新截图来自 `apple/scripts/xc.sh shot`（隔离演示库，见 docs/development.md），不碰真实用户数据。

## 产品文案定稿（对外描述的单一事实源）

- **GitHub 仓库 description**：
  `📝 Prompt Scratchpad for Coding Agents - Write Comfortably, Dispatch in One Tap | Vibe Coding 的灵感本，轻松一键发送给 Agent`
- **中文标语**：提示词写好，一键投送 · 副题：给 coding agents 设计的 macOS 草稿本 · 写好直达终端与编辑器
- **英文标语**：Write your prompt, dispatch in one tap · 副题：A macOS scratchpad for coding agents · straight to your terminal and editor
- hero / social 图的中英文案以此为准；英文图用 `?lang=en` 出（见下表）

| 路径 | 说明 |
| --- | --- |
| `shots/raw/`、`shots/final/` | 窗口截图（2400×1520 @2x）与加框成图；`compose/` 的 hero / social 模板读 `raw/board-light-collapsed.png`。新截图到位后替换 |
| `compose/` | HTML 合成模板 + `compose.mjs`（headless Chromium 精确画布出图；`auto` 尺寸按 body 截）；hero / social 模板支持 `?lang=en` 出英文版（`*-en-*.png`）。`compose.mjs` 需要 Node 与 `@playwright/test`（仓库不带 package.json，运行前 `npm i --no-save @playwright/test`） |
| `visual/` | 成图：README hero、GitHub social preview、抠图素材（`design/tools/cutout.swift` 产物） |
| `motion/demo-dispatch.gif` | README 的一键投送演示 GIF |
