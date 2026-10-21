# Contributing to CuePad

Thanks for your interest in CuePad. To build and run it, follow [Quick start](../README.md#quick-start) in the README. Project conventions, commands and guardrails are in [AGENTS.md](../AGENTS.md), with topic notes in [docs/](../docs/). Code comments and docs are mostly in Chinese; issues and PRs in English are fine.

## Setup

```bash
brew install ripgrep                          # used by the lint step of xc.sh check
git config core.hooksPath apple/scripts/hooks # pre-commit: lint and file-size gate
apple/scripts/xc.sh build mac                 # every build, test and screenshot goes through xc.sh
```

Builds from source never touch the released app's library: they open `~/Library/Application Support/CuePad Dev`, and `xc.sh run|shot` starts each instance with its own throwaway library.

## Before you open a pull request

1. Run `apple/scripts/xc.sh check`, plus the tests that cover your change: `xc.sh test kit` for the shared package, `xc.sh test mac` for the app.
2. Keep the diff scoped to the change at hand. Match the existing code style; don't reformat unrelated files.
3. Update the docs when interfaces or user-facing behavior change. Tests follow the rules in AGENTS.md: end-to-end flows only, no unit tests that restate the implementation.

## Commit and PR conventions

- Most commits use a [Conventional Commits](https://www.conventionalcommits.org) type, usually with a scope: `feat(mac): …`, `fix(pi): …`, `chore: …`. The description can be in Chinese or English.
- Write one logical change per commit.
- In the PR description, explain what changed and how you verified it.

## Reporting bugs and requesting features

Open an issue at https://github.com/Suge8/CuePad/issues. For a bug, include your macOS or iOS version, steps to reproduce, and what you expected to happen.
