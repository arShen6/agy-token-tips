# agy-token-tips v0.3.2

## Native macOS Obsidian HUD (`TokenLensHUD.app`) — Performance, Memory & Reliability Hardening

A standalone native Swift macOS app for Antigravity Desktop — **no custom launcher, no background daemon, no CDP injection, and no Antigravity restart required**.

**[Download `TokenLensHUD-macos-arm64.zip`](https://github.com/arShen6/agy-token-tips/releases/download/v0.3.2/TokenLensHUD-macos-arm64.zip)** (macOS 14+ Apple Silicon, ~448 KB)

### What's Fixed & Improved in v0.3.2
- **True Zero-Allocation Streaming Protobuf Decoder (`Protobuf.swift`)**: Parses directly over `UnsafeRawBufferPointer` skipping unknown fields in-place with zero `[Field]` array allocations or retained SQLite pointers — cutting real physical memory (`phys_footprint`) from **44 MB (99.1 MB peak)** down to **18 MB (19 MB peak)** and `MALLOC_LARGE` to **0 B**.
- **Incremental SQLite Correctness & Edge-Case Hardening (`DataStore.swift`)**:
  - Replaced O(n) `COUNT(*)` with O(log n) `MIN(idx)/MAX(idx)` plus `mainDbFingerprint` WAL-checkpoint invalidation.
  - Always re-reads the tail 3 rows to catch in-place streaming `UPDATE`s, preserves the latest Context Anatomy (`sections`) across sectionless appends, and guards 0-byte / `NULL` blobs.
  - Ephemeral `URLSession` (`urlCache = nil`), stat-cached `DevToolsActivePort`, throttled `2.5s` route checks, and `PRAGMA query_only = ON; cache_size = -512; mmap_size = 0`.
- **Event-Driven O(1) Window Tracking & Zero Background Wakeups (`main.swift`)**:
  - Unified launch/focus/wake lifecycle gate so background polling never leaks on startup.
  - Replaced 4 Hz full-machine `CGWindowListCopyWindowInfo` scans with O(1) cached `CGWindowID` lookup at a calm `1.5s` cadence, boosting to `0.16s` only while actively dragging.
  - Only invalidates WindowServer shadow on size changes; fixes expanded panel double-layout jump.
- **Race-Free `posix_spawn` Process-Group Isolation (`QuotaService.swift`)**:
  - Replaces blocking multi-thread `Process` reads with `posix_spawn` (`POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT`) + non-blocking `DispatchSource` I/O on a single serial queue.
  - Hard timeout kills the entire process group (`SIGTERM` → `SIGKILL`), reaps deterministically, and leaks **0 FDs / 0 orphan grandchildren** (verified under repeated SIGTERM-ignoring fault injection).
  - Respects macOS Low Power Mode for automatic background quota refreshes.
- **UI Render & Timer Hygiene (`Views.swift`)**:
  - Exact synthesized `Equatable` snapshot diffing (catches speed/TTFT/cache updates without hand-maintained whitelists).
  - Removed 120 Hz `ProgressView()` spinner during quota refreshes and moved `TimelineView` onto leaf countdown text only (`1s` for `5h`, `60s` for `7d`).

### First-Launch Note (Unsigned macOS Build)
Right-click `TokenLensHUD.app` → **Open**, or run `xattr -cr /Applications/TokenLensHUD.app && open /Applications/TokenLensHUD.app`. Legacy Windows/Linux/macOS v0.2.5 packages remain archived in the `v0.2.5` release.
