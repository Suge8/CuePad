# Security Policy

CuePad is a local-first desktop app. Your data stays on your machine in a local SQLite database; the app has no server, account system, or telemetry. The security surface is the Electron IPC bridge, the local database, and the macOS dispatch sidecar (which requires Accessibility permission to send keystrokes to other apps).

## Reporting a vulnerability

Please report security issues privately. Do not open a public issue for a vulnerability.

- Email: nnyless@foxmail.com
- Include a description, the steps to reproduce, and the affected version or commit.

You can expect an initial response within a few days. Once the issue is confirmed and fixed, we will credit you in the release notes unless you prefer to stay anonymous.

## Supported versions

CuePad is under active pre-1.0 development. Security fixes land on the latest `main` and the most recent release.
