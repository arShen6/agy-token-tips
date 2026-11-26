# agy-token-tips v0.3.3

## Native macOS Obsidian HUD (`TokenLensHUD.app`) — System Proxy Inheritance & No-Browser OAuth Guard

A standalone native Swift macOS app for Antigravity Desktop — **no custom launcher, no background daemon, no CDP injection, and no Antigravity restart required**.

**[Download `TokenLensHUD-macos-arm64.zip`](https://github.com/arShen6/agy-token-tips/releases/download/v0.3.3/TokenLensHUD-macos-arm64.zip)** (macOS 14+ Apple Silicon, ~450 KB)

### What's Fixed in v0.3.3
- **Automatic macOS System Proxy Inheritance (`QuotaService.swift`)**: GUI apps launched via Finder, Spotlight, or Login Items (`launchd`) do not inherit shell `HTTP_PROXY` / `HTTPS_PROXY` variables, causing `agy /usage` silent OAuth token refresh to time out behind Clash/Surge/VPN system proxies. `QuotaService` now reads macOS's live system proxy dynamically via `CFNetworkCopySystemProxySettings()` and injects `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` into the `agy` child environment (avoiding mixed-port `socks5://` conflicts).
- **Zero Background Browser Hijacking (`QuotaService.swift`)**: Passes non-interactive headless hints (`BROWSER=/usr/bin/false`, `SSH_CONNECTION`) and immediately aborts & surfaces a calm "not signed in" state if `agy` ever emits an interactive OAuth URL — preventing background quota polling from unexpectedly popping open browser login tabs or causing Google `400` callback errors on timeout.

### Previous Highlights (v0.3.2)
- Zero-allocation streaming Protobuf decoder (`18–19 MB` physical footprint, `0 B` `MALLOC_LARGE`).
- Incremental SQLite reader with WAL-checkpoint fallback, tail in-place UPDATE tracking, and O(1) CoreGraphics window tracking.
- `posix_spawn` process-group isolation with zero FD/grandchild leaks and automatic Low Power Mode skip.

### First-Launch Note (Unsigned macOS Build)
Right-click `TokenLensHUD.app` → **Open**, or run `xattr -cr /Applications/TokenLensHUD.app && open /Applications/TokenLensHUD.app`. Legacy Windows/Linux/macOS v0.2.5 packages remain archived in the `v0.2.5` release.
