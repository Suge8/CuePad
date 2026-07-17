# Contributing to CuePad

Thanks for your interest in CuePad. This guide covers how to set up the project, run the checks, and open a pull request.

## Prerequisites

- [Bun](https://bun.sh) — the task runner and test runner
- macOS (Apple Silicon) to run the desktop app; the one-tap dispatch feature is macOS-only
- Rust toolchain (`cargo`) — only needed to build the dispatch sidecar or package the app

Everyday development, the Chromium E2E suite, and the Electron E2E suite never invoke Cargo. Only `build:sidecar`, `test:sidecar`, and `package:app` compile Rust.

## Setup

```bash
git clone https://github.com/Suge8/CuePad.git
cd CuePad
bun install
bun run dev:electron   # Electron + a temporary Vite server
```

## Common commands

```bash
bun test              # Bun unit tests (repository, sorting, autosave, backup, shortcuts, sidecar client)
bun run check         # Svelte / TypeScript checks
bun run lint          # ESLint
bun run test:e2e      # Headless Chromium visual acceptance
bun run test:electron # Real Electron / preload / SQLite acceptance
bun run package:app   # Build the sidecar and produce release/mac-arm64/CuePad.app
```

More architecture and testing details live in [docs/development.md](../docs/development.md).

## Before you open a pull request

1. Run the checks that cover your change: `bun test`, `bun run check`, `bun run lint`, and the relevant E2E suite.
2. Keep the diff scoped to the change at hand. Match the existing code style; don't reformat unrelated files.
3. Add or update tests when you change behavior, and update the docs when interfaces or user-facing behavior change.

## Commit and PR conventions

- Use [Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `refactor:`.
- Write one logical change per commit.
- In the PR description, explain what changed and how you verified it.

## Reporting bugs and requesting features

Open an issue at https://github.com/Suge8/CuePad/issues. For a bug, include your macOS version, steps to reproduce, and what you expected to happen.
