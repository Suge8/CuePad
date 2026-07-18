# CuePad 开发文档

技术栈：Electron 37 + SvelteKit（Svelte 5）+ TypeScript + Tailwind CSS 4 + Bits UI + CodeMirror 6 + SQLite（Electron 主进程内置 `node:sqlite`）。桌面运行时仅 Electron，macOS 一键投送由独立 Rust sidecar 完成。

## 常用命令

```bash
bun run dev:electron  # Electron + 临时 Vite 服务；不编译 Rust
bun run build         # 构建静态 renderer 到 build/
bun run build:electron # 构建主进程与 preload 到 dist-electron/
bun run build:sidecar # 显式构建 macOS 投送 sidecar（唯一直接 Cargo 入口）
bun run test:sidecar  # 构建并验证 sidecar JSON 行协议
bun test              # Bun 单元测试
bun run check         # Svelte / TypeScript 检查
bun run lint          # ESLint
bun run test:e2e      # Playwright Chromium 无头 UI 验收
bun run test:electron # 真实 Electron / preload / SQLite 验收；不编译 Rust
bun run package:app   # 构建 sidecar，产出 .app + GitHub Release 用 zip
bun run test:package  # 验证已打包应用的 renderer、SQLite 与资源
```

日常开发、Chromium E2E 和 Electron E2E 都不会调用 Cargo。只有显式执行 `build:sidecar`、`test:sidecar` 或 `package:app` 才会编译 Rust。

## 运行时架构

### 主进程与安全桥

- `electron/main.ts` 持有 BrowserWindow、托盘、全局快捷键、剪贴板、SQLite 和 sidecar 生命周期。窗口关闭只隐藏；真正退出时才释放快捷键、托盘、数据库并等待 sidecar 关闭。
- `electron/preload.ts` 在 `contextIsolation: true`、`nodeIntegration: false`、`sandbox: true` 下只暴露类型化 `window.cuepad`。renderer 无法访问原始 `ipcRenderer`、Node 或文件系统。
- 开发态加载临时 Vite URL。打包态使用标准且安全的 `cuepad://app/` 本地协议，把 SvelteKit SPA fallback 的 `/_app/...` 资源映射到 app.asar 内 `build/`；路径越界请求返回 404。
- `CUEPAD_TEST=1` 创建隐藏且不聚焦的窗口并关闭后台节流，供真实 Electron 测试使用，不抢当前桌面焦点。

### SQLite 与迁移

- `src/lib/db/` 是运行时无关的 repository；renderer 只经 `window.cuepad.sql` 请求主进程。
- `electron/db.ts` 是连接与迁移的单一事实源：WAL、外键、5s busy timeout、同步 `BEGIN IMMEDIATE` 真事务。schema 位于根目录 `migrations/001–005`。
- 目标库是 `app.getPath('userData')/cuepad.db`。首次启动且目标库不存在时，主进程会从 `~/Library/Application Support/com.sugeh.cuepad/cuepad.db` 复制旧版 `.db/.db-wal/.db-shm`，主文件最后原子落位；源文件不改不删。
- 旧库的 `_sqlx_migrations` 成功版本会写入 `schema_migrations`，避免重复执行历史迁移。复制失败不会创建空库，renderer 明确展示加载错误。

### 工作区与编辑器

- `src/lib/workspace/store.svelte.ts` 是项目、卡片、任务、标签、回收站、主题和快捷键状态的单一事实源；`editor.svelte.ts` 持有沉浸编辑草稿。
- 项目置顶、卡片收藏只划分稳定展示分区；基础 `sort_order` 仍是拖拽恢复的持久事实源。任务是全局集合，活动项按基础顺序，完成项按完成时间展示。
- `src/lib/editor/autosave.ts` 使用 buffer → queue → 单一 drain 串行保存；每次写库前由 `backup.ts` 保存 localStorage 快照，成功后清除。
- `src/lib/motion.ts` 统一 Svelte transition、WAAPI 图标切换和 FLIP；`prefers-reduced-motion` 禁用位移、缩放与装饰循环，仅保留状态反馈和淡变。

### 桌面壳与一键投送

- `electron/shortcuts.ts` 在注册边界把 W3C code accelerator 转成 Electron accelerator。设置页的“注册 → SQLite 持久化 → 失败回滚”由 renderer 串行执行，主进程只持有注册表和固定显隐回调。
- `electron/tray.ts` 使用 18pt 模板图；1x/2x 文件位于 `electron/assets/`，打包后从 `Contents/Resources/assets/` 读取。
- `native/dispatch/` 是 macOS-only 长驻 sidecar。它订阅前台应用激活通知，通过 stdio JSON 行协议响应目标查询与投送请求，不轮询。
- 主进程把“权限/目标/CGEvent 预检 → 写剪贴板 → 隐藏窗口 → 激活目标 → 定向 `Cmd+V`”放入同一串行队列。失败会恢复窗口；目标未运行或权限不足会返回明确错误，不回退到其他应用。
- sidecar 等目标激活通知后才发送按键，并保留 100ms 有界消费窗口，防止连续投送覆盖前一次剪贴板。崩溃时当前请求失败，下次调用自动重启。
- 投送请求可携带 `submit: true`（UI 中的「自动发送」开关，偏好存 localStorage）：sidecar 在粘贴落地窗口后补发一次无修饰键回车，适合终端与聊天输入框。

## 打包

`electron-builder.yml` 产出 macOS arm64 `dir` + `zip`：

- appId：`com.sugeh.cuepad`
- 应用签名：ad-hoc（`identity: "-"`），不做 DMG 或公证
- `build/`、`dist-electron/`、`migrations/` 进入 app.asar
- `cuepad-dispatch` 与托盘/应用图标进入 `Contents/Resources/`
- 本地验收：`release/mac-arm64/CuePad.app`
- 分发产物：`release/CuePad-mac-arm64.zip`（稳定文件名，挂到 GitHub Releases；落地页经 `/releases/latest/download/` 直链）

营销落地页在 `landing/`，Vercel 项目 `cuepad-landing`（Root Directory = `landing/`，连 GitHub `main` 自动部署）；公开址 [cue-pad.com](https://cue-pad.com)。

构建后先运行：

```bash
bun run test:package
codesign --verify --deep --strict release/mac-arm64/CuePad.app
```

`test:package` 读取 `DevToolsActivePort` 并直接使用 CDP WebSocket，事件驱动等待 packaged renderer 首次加载；它验证 `cuepad://app/`、迁移 001–005、隔离数据库、运行应用列表和资源落位。物理全局热键、系统辅助功能授权、真实目标激活/粘贴与主观动效手感仍属于人工 smoke。

## 测试分层

1. **Bun 单元测试**（`tests/`、`electron/*.test.ts`）：repository、排序、自动保存、备份、快捷键编解码、托盘资源和 sidecar 客户端队列。
2. **Playwright Chromium**（`e2e/`）：完整桌面桥 mock 下的工作区、任务、弹层、响应式、真实鼠标拖拽、动效方向和减动分支。`e2e/run.ts` 为每次运行分配独立端口与 `/tmp/cuepad-e2e/<run-id>`；成功即删除，失败只保留 PNG/trace ZIP，启动时清理超过 7 天的 run。
3. **Playwright Electron**（`e2e-electron/*.e2e.ts`）：真实 preload、SQLite、Pin/Star、项目/卡片/任务拖拽落库、重启恢复、旧库继承、快捷键注册、剪贴板、close=hide 和 sidecar 客户端生命周期。全程隐藏且不聚焦。
4. **Packaged smoke**（`e2e-electron/package-smoke.ts`）：验证最终 `.app` 的本地协议、数据库和 extraResources。
5. **人工 smoke**：双击启动、真实日常数据、托盘菜单、物理全局热键、授权后的跨应用全文/分段投送。

自动测试禁止系统级合成鼠标/键盘。视觉 E2E 的动效断言由 `e2e/animation-recorder.js` 记录 WAAPI 属性，先订阅完成事件再触发操作；短过渡不做事后单帧猜测。真实拖拽使用 `page.mouse`，任务插入槽位由 Pointer Capture 状态机按活动行中点计算，不依赖 `elementFromPoint`。
