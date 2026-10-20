# design/promo 物料索引

宣传物料的合成模板与成图。新截图来自 `apple/scripts/xc.sh shot`（隔离演示库，见 docs/verify.md），不碰真实用户数据。

## 成图与仓库简介上的文案

产品事实以根 [README.md](../../README.md) 为准；这里只是现有物料与 GitHub 仓库简介上写着的字，改物料时一并对齐 README。

- **GitHub 仓库 description**：
  `📝 Prompt Scratchpad for Coding Agents - Write Comfortably, Dispatch in One Tap | Vibe Coding 的灵感本，轻松一键发送给 Agent`
- **中文标语**：提示词写好，一键投送 · 副题：给 coding agents 设计的 macOS 草稿本 · 写好直达终端与编辑器
- **英文标语**：Write your prompt, dispatch in one tap · 副题：A macOS scratchpad for coding agents · straight to your terminal and editor

| 路径 | 说明 |
| --- | --- |
| `shots/raw/`、`shots/final/` | 旧版界面的窗口截图与加框成图；`compose/` 的 hero / social 模板读的 `raw/board-light-collapsed.png` 还没有，补 Swift 版截图时放这里 |
| `compose/` | HTML 合成模板 + `compose.mjs`（headless Chromium 精确画布出图；`auto` 尺寸按 body 截）；hero / social 模板支持 `?lang=en` 出英文版（`*-en-*.png`）。`compose.mjs` 需要 Node 与 `@playwright/test`（仓库不带 package.json，运行前 `npm i --no-save @playwright/test`） |
| `visual/` | 成图：README hero、GitHub social preview、抠图素材（`design/tools/cutout.swift` 产物） |
