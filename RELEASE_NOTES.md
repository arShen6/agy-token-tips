# agy-token-tips v0.3.1

## Native macOS Obsidian HUD (`TokenLensHUD.app`)

A standalone native Swift macOS app for Antigravity Desktop — **no custom launcher, no background daemon, no CDP injection, and no Antigravity restart required**.

**[Download `TokenLensHUD-macos-arm64.zip`](https://github.com/arShen6/agy-token-tips/releases/download/v0.3.1/TokenLensHUD-macos-arm64.zip)** (macOS 14+ Apple Silicon, ~440 KB)

### Highlights
- **Minimal Obsidian Micro-Island (`146 × 32pt`)**: Auto-anchored to the bottom-right corner of your Antigravity window via CoreGraphics (follows move/resize/multi-monitor, remembers custom drag offset, auto-hides when switching apps). One-click toggle to **MacBook Physical Top Notch Island**.
- **Pure 2-State Hover-to-Expand**: Hover ~240ms to bloom directly into the zero-scroll **`652pt` Obsidian Command Center** without stealing focus; move away (~300ms) or click outside / press `Esc` to collapse.
- **Official 7d & 5h Remaining Quota**: Async background polling via official `agy -p /usage` (0 tokens) showing **Gemini Models** and **Claude / GPT** remaining `7d` (top) and `5h` (bottom) bars + live reset countdowns.
- **Ultra-Low Overhead**: Incremental SQLite reads + zero-copy protobuf slicing + background sleep — ~0.0%–0.2% CPU and ~28 MB memory.

### First-Launch Note (Unsigned macOS Build)
Right-click `TokenLensHUD.app` → **Open**, or run `xattr -cr /Applications/TokenLensHUD.app && open /Applications/TokenLensHUD.app`. Legacy Windows/Linux/macOS v0.2.5 packages remain archived in the `v0.2.5` release.
