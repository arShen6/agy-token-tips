# agy-token-tips

[English](README.md) | [简体中文](README.zh-CN.md)

Real-time **token speed (`tok/s`), TTFT wait, context window fill, cache hit rate, Swarm subagent rollup, and official 7d / 5h remaining quota** for **Antigravity Desktop** — now powered by a standalone native macOS Obsidian HUD (**zero launcher, zero DOM injection, zero Antigravity restart**).

---

## macOS Native HUD · Apple Silicon (Recommended — v0.3.0)

**[Download TokenLensHUD.app (.zip)](https://github.com/arShen6/agy-token-tips/raw/refs/heads/main/downloads/TokenLensHUD-macos-arm64.zip)** · [All Releases](https://github.com/arShen6/agy-token-tips/releases)

> Works natively on **macOS 14 Sonoma / 15 Sequoia / 26 Tahoe** (Apple Silicon). No custom Antigravity launcher, no Node.js runtime, no LaunchAgent daemon, no CDP injection, and survives Antigravity client updates.

### Quick Start (30 seconds)

1. **Download & Unzip** [`TokenLensHUD-macos-arm64.zip`](https://github.com/arShen6/agy-token-tips/raw/refs/heads/main/downloads/TokenLensHUD-macos-arm64.zip) and drag **`TokenLensHUD.app`** into `/Applications`.
2. **Open `TokenLensHUD.app`**:
   - Because this community build is ad-hoc signed (not Apple notarized), macOS Gatekeeper may show a warning on first launch. Unlock it in either way:
     - **GUI**: Right-click `TokenLensHUD.app` → **Open** (or go to **System Settings → Privacy & Security → Open Anyway**).
     - **Terminal (fastest)**:
       ```bash
       xattr -cr /Applications/TokenLensHUD.app && open /Applications/TokenLensHUD.app
       ```
3. **Use Antigravity as usual** (no restart needed!):
   - A minimal obsidian micro-island (`◯ 20% · 112 t/s`) automatically attaches to the **bottom-right corner of your Antigravity window** and follows it across moves, resizes, and monitors (auto-hides when switching to other apps).
   - **Hover** over the micro-island (~240ms) to smoothly expand the full zero-scroll **Obsidian Command Center**; move your cursor away (~300ms) or click outside / press `Esc` to collapse.
   - **Drag** the micro-island to fine-tune its offset relative to Antigravity's bottom-right corner; **right-click** the micro-island (or menu bar gauge icon) to toggle **MacBook Top Physical Notch Island**, switch to **click-only expand**, reset corner position, or **Quit**.
4. *(Optional)* **Auto-start at login**: Add `TokenLensHUD.app` in **System Settings → General → Login Items**.
5. *(Optional)* **Official 7d / 5h Quota**: If `agy` CLI (`~/.local/bin/agy` or Homebrew `agy`) is installed and signed in, the HUD automatically queries official `agy -p /usage` asynchronously in the background (**0 turns, 0 tokens consumed**) and displays **Gemini** and **Claude / GPT** remaining `7d` (top) and `5h` (bottom) quotas with live countdown timers.

### Build Locally from Source (Zero Gatekeeper Prompt)

Requires only Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/arShen6/agy-token-tips.git
cd agy-token-tips
bash macos-hud/build.sh
open macos-hud/dist/TokenLensHUD.app
```

### What You See in the Native HUD

| Area | Details |
| --- | --- |
| **Micro-Island (Resting)** | Context fill ring + `%` · live generating pulse · latest speed (`t/s`). Pure obsidian finish (`146 × 32pt`) anchored to Antigravity's bottom-right corner (or MacBook top notch). |
| **Official Model Quota** | **Gemini Models** & **Claude / GPT** remaining **`7d`** (top) and **`5h`** (bottom) progress bars + live second-by-second reset countdowns, auto-highlighting the active conversation's model family. |
| **4-Column KPIs** | Streaming / End-to-end `tok/s`, TTFT / Hold wait, latest output (`Thinking` + `Response`), cumulative cache hit rate. |
| **Unified Context Window** | Segmented bar showing conversation + system prompt anatomy (Skills, Subagents, User Rules, MCP, Core), 75% warning / 90% critical markers, estimated calls runway before `/compact`, and cache-drop alerts. |
| **Session & Swarm Sync** | Automatic active-conversation sync + inline switcher + Swarm / Subagent token rollup + latest 5 calls table. |

---

## Legacy Composer-Bar Mode · Windows / Linux x64 (Experimental) & Old macOS Launcher

If you are on **Windows / Linux**, or specifically prefer the older Electron composer-footer bar launched via CDP debugging port, the legacy installers remain available:

- **macOS legacy launcher**: [AGY-Token-Tips-macos-arm64.zip](https://github.com/arShen6/agy-token-tips/raw/refs/heads/main/downloads/AGY-Token-Tips-macos-arm64.zip) + helper ([English](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-macos-arm64-en.zip) · [Chinese](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-macos-arm64-zh-CN.zip))

| Platform | Download helper | Install once | Open Antigravity |
| --- | --- | --- | --- |
| Windows x64 | [English](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-windows-x64-en.zip) · [Chinese](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-windows-x64-zh-CN.zip) | Double-click `install.cmd` | Double-click `start-antigravity.cmd` |
| Linux x64 | [English](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-linux-x64-en.zip) · [Chinese](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-linux-x64-zh-CN.zip) | Run `bash install.sh` | Run `bash start-antigravity.sh` |

![Legacy composer-bar preview](assets/agy-preview.png)

<details>
<summary>Manage legacy helper, technical architecture & development</summary>

### Privacy & Architecture (Native macOS HUD)
- **Strictly read-only SQLite**: Reads `~/.gemini/antigravity/conversations/<uuid>.db` (`gen_metadata`) and `conversation_summaries.db` with `SQLITE_OPEN_READONLY` + `PRAGMA query_only = ON`, stat-cached and closed immediately after each read (<2ms).
- **Window attachment**: Uses public CoreGraphics window bounds (`CGWindowListCopyWindowInfo`) — no Accessibility permission required, no process injection, no app bundle modification.
- **Official Quota**: Runs `agy --output-format json -p /usage` asynchronously (single-flight, 20s timeout, cached in `~/Library/Application Support/TokenLensHUD/quota-cache.json`). Zero tokens consumed; no credentials scraped or uploaded.

### Manage Legacy Helper

| Action | macOS | Windows | Linux |
| --- | --- | --- | --- |
| English details | `install-en.command` | `install-en.cmd` | `install-en.sh` |
| Chinese details | `install-zh.command` | `install-zh.cmd` | `install-zh.sh` |
| Check status | `status.command` | `status.cmd` | `status.sh` |
| Uninstall | `uninstall.command` | `uninstall.cmd` | `uninstall.sh` |

### Legacy Node.js Source Development (Node.js >=22.16)

```bash
bash start.sh start --language en
bash start.sh doctor
npm test
npm run demo
```

More protocol notes: [docs/protocol.md](docs/protocol.md).

</details>

## Contribute

Issues and pull requests are welcome — compatibility fixes, translations, and platform support. See [CONTRIBUTING.md](CONTRIBUTING.md).

Inspired by [chuanban-antigravity-theme-patch](https://github.com/Anarcadia/chuanban-antigravity-theme-patch). Independently implemented. [MIT License](LICENSE). Unofficial, not affiliated with Google.
