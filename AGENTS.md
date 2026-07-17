# CuePad 模块索引

产品定位与功能见 [README.md](README.md)；开发命令、架构要点与验收环境事实见 [docs/development.md](docs/development.md)。

| 模块 | 职责 |
| --- | --- |
| `src/lib/db/` | 运行时无关的 SQLite repository：projects / cards / tasks / tags / trash / settings / search；renderer 经 `window.cuepad.sql` 调用 |
| `electron/` | Electron 主进程与 preload；`db.ts` 负责 `node:sqlite`、旧版数据继承、迁移和真事务，`ipc-sql.ts` 暴露 SQL IPC，`sidecar.ts` 管理投送子进程、协议、串行队列与生命周期 |
| `native/dispatch/` | macOS 一键投送 Rust sidecar：前台应用追踪、目标解析、Accessibility 检查、激活与定向 `Cmd+V` |
| `src/lib/workspace/` | 工作区 UI 与状态：`store.svelte.ts`（当前项目/全局收藏/任务单一事实源）、`editor.svelte.ts`（沉浸编辑）、`dispatch.ts`（复制/投送入口）、`CardBoard.svelte`（横向项目栏 + 单项目卡片墙）、`TaskStack.svelte`（全局悬浮任务）、命令面板、设置、回收站 |
| `src/lib/editor/` | CodeMirror 封装、轻量装饰（decorations）、块系统（控件化分隔线/编号/排版复制/块快捷键，`segments.ts` `blocks.ts`）、变量模板（`variables.ts`）、自动保存、本地备份 |
| `src/lib/shell/` | 全局快捷键注册与 accelerator 编解码 |
| `src/lib/ui/` | 通用 UI 原子组件（Button / Toast / Dialog / 色板 / Mascot 吉祥物等） |
| `src/lib/assets/` | 品牌 IP 透明底定稿（空状态/关于页用）；源图与 logo 定稿在 `design/final/` |
| `migrations/` | 运行时无关的 SQLite schema 迁移（001–005） |
| `tests/` | bun test（repository，含 tasks / segments / autosave / backup / accelerator / search） |
| `e2e/` | 无头视觉验收：Playwright Chromium + 桌面桥 mock，覆盖工作区、悬浮任务、真实鼠标拖拽、动效与响应式布局（`bun run test:e2e`） |
| `e2e-electron/` | 真实 Electron 验收：安全桥、SQLite CRUD/事务、Pin/Star 与三类拖拽落库、重启/旧库恢复；`package-smoke.ts` 验证最终 `.app`（`bun run test:electron` / `bun run test:package`） |
| `electron-builder.yml` | macOS arm64 `.app` 打包事实源：ad-hoc 签名、app.asar 内容、sidecar 与图标 extraResources |
