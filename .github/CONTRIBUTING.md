# Contributing to CuePad

Thanks for your interest in CuePad. This guide covers how to set up the project, run the checks, and open a pull request.

## Prerequisites

- macOS with Xcode 27 (the app targets macOS 26 and iOS/iPadOS 27)
- No developer account is needed: local builds and tests are ad-hoc signed. Only the release commands need App Store Connect credentials (see [docs/development.md](../docs/development.md)).

## Setup and common commands

```bash
git clone https://github.com/Suge8/CuePad.git
cd CuePad
apple/scripts/xc.sh build mac     # build the Mac app
apple/scripts/xc.sh test mac      # app tests (Mac)
apple/scripts/xc.sh build ios     # build for the iPhone simulator
cd apple/CuePadKit && swift test  # shared package: store, sync, editor, Pi bridge, command line
```

`xc.sh` builds into `apple/.derived/`. If several builds run at once, give each its own directory: `CUEPAD_DERIVED=/tmp/xxx apple/scripts/xc.sh build mac`.

Architecture, conventions, and the screenshot workflow live in [docs/development.md](../docs/development.md).

## Before you open a pull request

1. Run the checks that cover your change: `swift test` in `apple/CuePadKit` for package changes, `xc.sh test mac` for app changes, and `xc.sh build ios` when you touch shared code.
2. Keep the diff scoped to the change at hand. Match the existing code style; don't reformat unrelated files.
3. Add or update tests when you change behavior, and update the docs when interfaces or user-facing behavior change.

## Commit and PR conventions

- Use [Conventional Commits](https://www.conventionalcommits.org): `feat:`, `fix:`, `docs:`, `test:`, `chore:`, `refactor:`.
- Write one logical change per commit.
- In the PR description, explain what changed and how you verified it.

## Reporting bugs and requesting features

Open an issue at https://github.com/Suge8/CuePad/issues. For a bug, include your macOS or iOS version, steps to reproduce, and what you expected to happen.
