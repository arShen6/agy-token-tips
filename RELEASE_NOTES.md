# agy-token-tips v0.3.0

## New: Native macOS Obsidian HUD (`TokenLensHUD.app`)

A standalone native Swift macOS app for Antigravity Desktop — **no custom launcher, no Node.js runtime, no LaunchAgent daemon, no CDP DOM injection, and no Antigravity restart required**.

**[Download `TokenLensHUD-macos-arm64.zip`](https://github.com/arShen6/agy-token-tips/releases/download/v0.3.0/TokenLensHUD-macos-arm64.zip)** (macOS 14+ Apple Silicon)

### Highlights
- **Minimal Obsidian Micro-Island (`146 × 32pt`)**: Dynamically anchors to the bottom-right corner of your Antigravity window via CoreGraphics (follows move/resize/multi-monitor, remembers custom drag offset, auto-hides when switching apps). One-click toggle to **MacBook Physical Top Notch Island**.
- **Pure 2-State Hover-to-Expand**: Hover ~240ms to bloom directly into the zero-scroll **`652pt` Obsidian Command Center** without stealing focus; move away (~300ms) or click outside / press `Esc` to collapse (optionally switch to click-only in footer/right-click).
- **Official 7d & 5h Remaining Quota**: Async background polling via official `agy -p /usage` (zero turns, zero tokens consumed) displaying **Gemini Models** and **Claude / GPT** remaining `7d` (top) and `5h` (bottom) bars + live reset countdowns.
- **Full Session Telemetry**: Streaming / end-to-end `tok/s`, TTFT / Hold wait, Thinking vs Response output, cache hit rate & drop alerts, unified segmented Context Window anatomy + runway estimate, Swarm / subagent token rollup, inline session switcher, and safe quit (right-click only).

### First-Launch Note (Unsigned macOS Build)
Run `xattr -cr /Applications/TokenLensHUD.app` or use **Right-Click → Open** / **System Settings → Privacy & Security → Open Anyway**, or compile locally with zero Gatekeeper prompt via `bash macos-hud/build.sh`.

---

## Legacy Installers (macOS / Windows / Linux x64)

Legacy composer-bar installers for Windows/Linux x64 and macOS remain included in this release for users who prefer the previous setup.
