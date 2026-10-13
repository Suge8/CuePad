<p align="right">English | <a href="README.zh-CN.md">简体中文</a></p>

<!-- TODO 截图待更新：以下图片仍是旧版界面，Swift 版截图另行安排，路径保持不变即可替换 -->
<p align="center">
  <img src="design/promo/visual/hero-readme-en-2400x1260.png" alt="CuePad: write your prompt, hand it to your agent" width="820" />
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue.svg" alt="License: Apache 2.0" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%2026%20%7C%20iOS%2027-111111.svg" alt="Platform: macOS 26, iOS/iPadOS 27" />
</p>

**CuePad is a thinking space for working with coding agents.** Jot down ideas, turn the ones to do into tasks, see what your agents are doing, and hand text to them in one tap. A calm, paper-like notebook, native on Mac, iPhone and iPad, synced through iCloud.

Local-first: everything lives in a SQLite database on your device; iCloud sync uses your own private CloudKit database. No account, no server, no telemetry.

## Features

- **Idea → task → agent.** Ideas are your library — any amount of text with inline images, `{{variables}}` and dividers. When it's time to act, attach an idea to a task and it becomes one of the task's prompts — what you hand to the agent, sent in one tap, showing whether the agent has replied — plus a checklist of steps if needed. Projects are just containers with a one-line intro. Everything autosaves.
- **Send to agents.** A task's prompts go straight to a running agent session (currently [Pi](https://pi.dev); text and images). Every send is logged with a snapshot and can be resent; you can always copy the text too.
- **See your agents.** Agent sessions show live state (thinking, running a tool, waiting for you, done) and history; sessions file under the project bound to their working directory.
- **Demos on your phone.** An agent can send a page, screenshot, PDF or report to you: it shows up as a card in the session on your phone, and tapping it opens a full-screen preview. (CuePad installs a small skill for Pi so the agent knows to run `cuepad show <file>`.)
- **Projects that know your code.** Bind a project to a code directory: agent sessions and the `cuepad` command line pick the right project from where they run.
- **Selections and variables.** Send a whole prompt or just the selected part, or turn selected lines into tasks; fill `{{variables}}` right before sending, each one remembers its last values.
- **Search everywhere.** `⌘K` searches projects, ideas and tasks, filtered by project, images, whether it went to an agent, or time.
- **Mac.** Glass sidebar, a menu bar scratch pad for quick ideas, and a global shortcut (`Option + Space` by default) to bring CuePad up from anywhere.
- **iPhone and iPad.** A project bookshelf, quick capture bar, share extension and widgets. Ideas written on the phone are on the Mac a moment later, and the phone can send text to an agent session on your Mac.
- **iCloud sync.** Per-record sync; if the same idea or task is edited offline on two devices, both versions are kept for you to choose from.

## `cuepad`: memory for your agents

`cuepad` is a command line that reads and writes the same library as the app, so an agent can look things up, take notes and keep a to-do list between sessions:

```bash
cuepad search deploy script        # find ideas and tasks (every word must match)
printf 'Release checklist…' | cuepad card add   # save an idea
cuepad task add Write release notes
cuepad task done <id>
```

Run inside a directory that a project is bound to and it works on that project by default. `--json` gives stable output for agents. It's linked into your PATH when you connect Pi (below); `cuepad --help` and `cuepad <command> --help` are the full reference.

## Connecting Pi (Mac)

The first time CuePad finds Pi on your Mac, it asks once whether to connect. Connecting writes three files:

- `~/.pi/agent/extensions/cuepad-bridge.ts`: lets CuePad see your Pi sessions and send prompts into them
- `~/.pi/agent/skills/cuepad/SKILL.md`: tells the agent how to send files to your phone
- `~/.local/bin/cuepad`: a link to the `cuepad` command line inside the app

CuePad keeps them current when the app updates or moves. To remove them, turn off **接入 Pi** (Connect Pi) in Settings; files with the same names that CuePad didn't write are left alone. Before deleting the app, turn it off in Settings or delete those three paths yourself (if you set `PI_CODING_AGENT_DIR`, the first two are under that directory instead of `~/.pi/agent`).

## Download

Get the latest Mac build from [GitHub Releases](https://github.com/Suge8/CuePad/releases/latest) (Developer ID signed and notarized; macOS 26 or later). iPhone and iPad builds ship through TestFlight. Product site: [cue-pad.com](https://cue-pad.com).

## Build from source

Requires Xcode 27. Local builds are ad-hoc signed, so no developer account is needed.

```bash
git clone https://github.com/Suge8/CuePad.git
cd CuePad
apple/scripts/xc.sh build mac    # also: build ios, test mac, shot mac
cd apple/CuePadKit && swift test
```

Commands and conventions for contributors: [AGENTS.md](AGENTS.md) and [docs/](docs/).

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](.github/CONTRIBUTING.md), and [SECURITY.md](.github/SECURITY.md) for reporting vulnerabilities.

## License

Apache License 2.0. See [LICENSE](LICENSE).
