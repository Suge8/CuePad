<p align="right">English | <a href="README.zh-CN.md">简体中文</a></p>

<p align="center">
  <img src="design/promo/visual/hero-readme-2400x1260.png" alt="CuePad: write your prompt, dispatch it in one tap" width="820" />
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue.svg" alt="License: Apache 2.0" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%20(Apple%20Silicon)-111111.svg" alt="Platform: macOS (Apple Silicon)" />
</p>

CuePad is a lightweight local prompt scratchpad built for the coding-agent workflow: open it fast, write comfortably, autosave, and dispatch your prompt to the terminal or editor you were just using in one keystroke.

It ships as a macOS Electron app with a Svelte interface. Your data stays on your machine in a local SQLite database.

<p align="center">
  <img src="design/promo/motion/demo-dispatch.gif" alt="Open a card in CuePad, tap dispatch, and the prompt lands in the terminal" width="720" />
</p>

## Features

- **Projects and cards.** Switch the active project in the horizontal project bar and pin the ones you use often. Global Favorites gathers starred cards from every project; unfiled notes land in the inbox.
- **Floating tasks.** Jot tasks beside the main view, assign them to a project, reorder by drag, and complete or restore them. Narrow windows keep a single task entry.
- **Immersive editing.** Click a card to write full-screen. `## headings`, `- lists`, code blocks, and `{{variables}}` get light visual treatment while the body always saves as plain text.
- **Autosave.** Every keystroke persists to the database. A local backup and retry keep your text safe when a write fails.
- **Split copy.** A lone `---split---` line cuts a draft into segments. Copy the whole draft or any single segment.
- **One-tap dispatch (macOS).** Leave your cursor in the target input. CuePad sends the text to the previous app by default, or to a pinned Terminal, iTerm, Zed, or VSCode.
- **Variable templates.** Fill in `{{variables}}` before you copy or dispatch. Each card remembers your last values.
- **Global search.** `Cmd/Ctrl + F` opens the palette. Search projects, card titles and bodies, and tags, then press Enter to jump.
- **Trash.** Projects and cards are soft-deleted, so you can restore or purge them.
- **Runs in the background.** Closing the window only hides it. `Alt/Option + Space` (configurable) summons it anytime, and the tray menu shows, hides, or quits.
- **Light, dark, and system themes.** Data lives in a local SQLite database.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `Cmd/Ctrl + F` | Search / command palette |
| `Esc` | Exit immersive editing / close a panel |
| `Alt/Option + Space` | Show / hide the window globally (configurable) |

## Screenshots

<details>
<summary>Immersive editing / split dispatch / variable templates / global search / floating tasks / dark theme</summary>
<p align="center">
  <img src="design/promo/shots/final/editor-light-2176.png" alt="Immersive editing" width="760" />
  <img src="design/promo/shots/final/segments-light-2176.png" alt="Split dispatch" width="760" />
  <img src="design/promo/shots/final/variables-light-2176.png" alt="Variable templates" width="760" />
  <img src="design/promo/shots/final/search-light-2176.png" alt="Global search" width="760" />
  <img src="design/promo/shots/final/tasks-light-2176.png" alt="Floating tasks" width="760" />
  <img src="design/promo/shots/final/board-dark-2176.png" alt="Dark theme" width="760" />
</p>
</details>

## Build from source

```bash
git clone https://github.com/Suge8/CuePad.git
cd CuePad
bun install
bun run package:app   # produces release/mac-arm64/CuePad.app
```

To run in development instead:

```bash
bun run dev:electron
```

**Requirements:** [Bun](https://bun.sh), macOS (Apple Silicon), and a Rust toolchain for packaging the dispatch sidecar. The app is ad-hoc signed and not notarized, so on first launch you may need to right-click it and choose **Open**.

The architecture, commands, and test layers are documented in [docs/development.md](docs/development.md).

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](.github/CONTRIBUTING.md) for setup, commands, and conventions, and [SECURITY.md](.github/SECURITY.md) to report a vulnerability.

## License

CuePad is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.
