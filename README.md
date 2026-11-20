# agy-token-tips

[English](README.md) | [简体中文](README.zh-CN.md)

Open Antigravity Desktop with **AGY Token Tips** to see token usage, context fill, generation speed and first-token wait beside the message box.

## macOS · Apple Silicon

**[Download the Mac launcher (.zip)](https://github.com/arShen6/agy-token-tips/raw/refs/heads/main/downloads/AGY-Token-Tips-macos-arm64.zip)**

1. **First time using token tips?** With Antigravity Desktop installed, download the metrics helper with [English tooltips](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-macos-arm64-en.zip) or [Chinese tooltips](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-macos-arm64-zh-CN.zip). Extract the folder and double-click `install.command` once. If you already installed the helper, skip this step.
2. Unzip the **Mac launcher** linked above, move `AGY-Token-Tips.app` to Applications and add it to your Dock.
3. **From now on, click AGY Token Tips to open Antigravity.** Send a message. The metrics appear beside the message box after the first model call finishes.

If Antigravity is already open and the launcher asks to reopen it, save your work before choosing **Quit and reopen**.

## Windows and Linux · x64 (experimental)

With Antigravity Desktop installed, extract the ZIP for your platform and run the installer once. Save your work and quit Antigravity before using the launcher for the first time. Use the launcher again after a full exit. All helper downloads include Node.js.

| Platform | Download helper | Install once | Open Antigravity |
| --- | --- | --- | --- |
| Windows | [English](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-windows-x64-en.zip) · [Chinese](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-windows-x64-zh-CN.zip) | Double-click `install.cmd` | Double-click `start-antigravity.cmd` |
| Linux | [English](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-linux-x64-en.zip) · [Chinese](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-linux-x64-zh-CN.zip) | Run `bash install.sh` | Run `bash start-antigravity.sh` |

Run these scripts from the extracted folder as your normal user. Windows requires Task Scheduler and Windows PowerShell. Linux requires a desktop session with user systemd. Both packages have automated checks. Live Antigravity UI compatibility still needs confirmation. [Report an issue](https://github.com/arShen6/agy-token-tips/issues/new?template=bug_report.md).

![agy-token-tips showing speed, wait time, context usage and detailed statistics in Antigravity](assets/agy-preview.png)

*Preview from an earlier build. Current details explicitly distinguish streaming and end-to-end speed.*

## What you see

A compact bar beside your composer. Hover for the details — no separate dashboard to open.

| Metric | What it shows |
| --- | --- |
| **Ctx** | Context tokens used / limit, plus percentage |
| **tok/s** | Output speed of the latest model call |
| **TTFT / Hold** | First-token wait / wait for buffered output |
| **Out** | Output tokens in the latest call |
| **Hover details** | Reasoning and response/tool output, session totals |
| **Cache** | Cached input and cache hit rate |

Context usage turns **yellow at 75%** and **red at 90%**. The strip stays in English; tooltips are available in English or Chinese. Data may update after a model call completes.

## Manage the helper

The helper starts automatically at login. Use the scripts in the extracted installer folder to change the tooltip language, check status or uninstall.

| Action | macOS | Windows | Linux |
| --- | --- | --- | --- |
| English details | `install-en.command` | `install-en.cmd` | `install-en.sh` |
| Chinese details | `install-zh.command` | `install-zh.cmd` | `install-zh.sh` |
| Check status | `status.command` | `status.cmd` | `status.sh` |
| Uninstall | `uninstall.command` | `uninstall.cmd` | `uninstall.sh` |

These community installers are unsigned. Your OS or file manager may ask you to confirm opening them. Windows ARM, Linux ARM and Intel Mac standalone packages are not included in this release.

## Understand the numbers

**Streaming speed** excludes the initial wait. **End-to-end speed** includes it. Both are labeled separately in the tooltip, which repeats the same speed shown in the bar. Potentially buffered output uses end-to-end speed and the `Hold` label.

Counts come from local usage metadata. Unknown values stay `—`; tokens are not guessed from text length. These are conversation metrics, not billing or remaining account quota.

<details>
<summary>Technical details, troubleshooting and development</summary>

This is an unofficial local UI patch, not a VSIX extension. It reads local `gen_metadata` records and uses a loopback debugging connection to mount the strip. No API key or chat/metrics uploads. No application bundle modification.

macOS retains `~/Library/Application Support/AGY Metrics` and its LaunchAgent identity for upgrade compatibility. Windows installs under `%LOCALAPPDATA%/agy-token-tips`; Linux uses `$XDG_DATA_HOME/agy-token-tips` (normally `~/.local/share/agy-token-tips`). It installs an independent copy, so the downloaded folder can be moved afterward. Uninstall removes login startup and the service; logs and backups remain, and Antigravity conversations are untouched.

If metrics are missing, finish a model call and run the status script for your platform. `ready: true` means the widget was detected in an actual window. Logs are in the installation directory’s `logs` folder. Linux service diagnostics: `journalctl --user -u agy-token-tips.service -n 50`. Client updates may require adjustments to the private data format or UI hooks. Report your app/OS versions and redacted errors; do not upload conversation databases.

Source development requires Node.js >=22.16:

```bash
bash start.sh start --language en
bash start.sh doctor
npm test
npm run demo
```

The demo uses simulated data. Windows/Linux packages are experimental: automated tests and native runtime/launcher checks do not establish live UI compatibility. More details: [protocol.md](docs/protocol.md).

</details>

## Contribute

Issues and pull requests are welcome — compatibility fixes, translations and installation improvements. See [CONTRIBUTING.md](CONTRIBUTING.md). Proposals for other clients need verified data sources and live-client evidence.

Inspired by [chuanban-antigravity-theme-patch](https://github.com/Anarcadia/chuanban-antigravity-theme-patch). Independently implemented; no code or theme assets from that project are bundled. [MIT License](LICENSE). Unofficial, not affiliated with Google. Node.js retains its own license in `runtime/LICENSE`.
