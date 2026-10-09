# Security Policy

CuePad is a local-first app for macOS, iPhone and iPad. Your data stays on your devices in a local SQLite database and, if you use sync, in your own private iCloud (CloudKit) database; the app has no server, account system, or telemetry. The security surface is the local database and its command line (`cuepad`), the Pi bridge (a per-user Unix socket), iCloud sync, and on macOS the Apple Events used to bring a session's terminal window to the front.

## Reporting a vulnerability

Please report security issues privately. Do not open a public issue for a vulnerability.

- Email: nnyless@foxmail.com
- Include a description, the steps to reproduce, and the affected version or commit.

You can expect an initial response within a few days. Once the issue is confirmed and fixed, we will credit you in the release notes unless you prefer to stay anonymous.

## Supported versions

CuePad is under active pre-1.0 development. Security fixes land on the latest `main` and the most recent release.
