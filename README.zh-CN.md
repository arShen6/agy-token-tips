# agy-token-tips

[English](README.md) | [简体中文](README.zh-CN.md)

为 **Antigravity Desktop** 打造的原生态实时监控助手：随时掌握 **输出速度（`tok/s`）、首字等待（TTFT）、上下文占比、缓存命中率、Swarm 子代理合并消耗、以及官方 7 天 / 5 小时剩余额度**。

现已全面升级为 **原生 macOS 黑曜石悬浮微岛（`TokenLensHUD.app`）**——**无需专用启动器、无需后台守护脚本、无需 Node.js、无需 CDP 注入、不重启 Antigravity、客户端升级也不失效**。

---

## macOS 原生黑曜石微岛 · Apple 芯片（推荐 — v0.3.0）

**[点击直接下载 TokenLensHUD.app（ZIP，约 500 KB）](https://github.com/arShen6/agy-token-tips/raw/refs/heads/main/downloads/TokenLensHUD-macos-arm64.zip)** · [查看全部 Releases](https://github.com/arShen6/agy-token-tips/releases)

> 原生 Swift 编写，支持 **macOS 14 Sonoma / 15 Sequoia / 26 Tahoe**（M1 / M2 / M3 / M4 等 Apple 芯片）。开箱即用，与 Antigravity 宿主完全解耦。

### 30 秒上手

1. **下载并解压** 上方的 [`TokenLensHUD-macos-arm64.zip`](https://github.com/arShen6/agy-token-tips/raw/refs/heads/main/downloads/TokenLensHUD-macos-arm64.zip)，把 **`TokenLensHUD.app`** 拖入「应用程序（`/Applications`）」。
2. **首次打开授权**（开源个人打包未经 Apple 付费公证，首次打开系统会拦截提示，任选其一放行即可）：
   - **图形界面**：右键点击 `TokenLensHUD.app` → **打开**（或在「系统设置 → 隐私与安全性」底部点 **仍要打开**）。
   - **终端一行放行（最快）**：
     ```bash
     xattr -cr /Applications/TokenLensHUD.app && open /Applications/TokenLensHUD.app
     ```
3. **正常打开或继续使用 Antigravity（无需重启）**：
   - **极简黑曜石微岛（`146 × 32pt`）** 会自动吸附在 **Antigravity 客户端窗口的右下角**，静息时只露 `◯ 上下文% · 速度 t/s`，AGY 拖动/缩放/移到副屏都会自动紧跟，切去其他软件时自动隐身不挡屏。
   - **鼠标悬停约 0.24 秒**直接一步展开零滚动 **652pt 暗曜总控台**，移开鼠标约 0.3 秒自动丝滑收起（点外部或按 `Esc` 也会立即收起）。
   - **自定义与防误触**：按住微岛可微调相对 AGY 右下角的偏移并自动记忆；**右键微岛**（或右键顶部状态栏的仪表盘图标）可随时一键切换为 **MacBook 物理顶刘海灵动岛**、关闭悬停改为纯点击展开、重置位置，或**退出程序**（详情面板内不放退出按钮，彻底杜绝手滑误退）。
4. *（可选）* **开机自启**：在「系统设置 → 通用 → 登录项与扩展」中把 `TokenLensHUD.app` 加入登录时打开即可。
5. *（可选）* **开启官方 7 天 / 5 小时剩余额度**：本机装有并登录了官方 `agy` CLI（`~/.local/bin/agy` 或 Homebrew `agy`）时，会自动在后台异步调用 `agy -p /usage`（**0 轮对话、0 Token 消耗**），在面板顶部实时展示 **Gemini** 与 **Claude / GPT** 两组模型的 **`7天`（上）与 `5h`（下）剩余额度及每秒跳动倒计时**；未安装 `agy` 时其余会话指标照常可用。

### 开发者本地一行编译（零 Gatekeeper 弹窗）

只需 macOS 自带的 Xcode 命令行工具（`xcode-select --install`）：

```bash
git clone https://github.com/arShen6/agy-token-tips.git
cd agy-token-tips
bash macos-hud/build.sh
open macos-hud/dist/TokenLensHUD.app
```

### 你能看到什么

| 模块 | 展示内容 |
| --- | --- |
| **极简微岛（静息态）** | 上下文进度环 + `%` · 生成中蓝色呼吸点 · 实时速度 `t/s`。默认吸附 AGY 右下角，可一键切至 MacBook 顶部物理刘海。 |
| **官方模型额度（剩余）** | **Gemini 模型组**与 **Claude / GPT 组**的 **`7天`（在上）与 `5h`（在下）** 剩余进度条与重置倒计时，自动高亮当前会话所属模型组，与 AGY 原生顺序一致。 |
| **4 列核心 KPI** | 流式 / 端到端速度 `tok/s`、首字等待 `TTFT` / 缓冲等待 `Hold`、本次输出（思考/回复拆分）、累计缓存命中率。 |
| **上下文窗口与构成合一** | 分段展示对话历史与系统提示词开销（Skills / 子代理 / 用户规则 / MCP / 系统核心），含 75% 橙色 / 90% 红色警戒线、剩余可聊轮数估算与缓存突降提醒。 |
| **会话同步与子代理树** | 自动跟随当前 Antigravity 活跃会话 + 内置无焦冲突会话切换器 + Swarm / 子代理合并 Token 树 + 最近 5 次调用明细。 |

---

## 旧版输入框嵌入模式 · Windows / Linux x64（实验版）与旧 macOS 启动器

如果你使用 **Windows / Linux**，或者偏好早期通过本机 CDP 端口将数字条直接塞进输入框旁的方案，仍可使用原有版本：

- **旧版 macOS 启动器**：[AGY-Token-Tips-macos-arm64.zip](https://github.com/arShen6/agy-token-tips/raw/refs/heads/main/downloads/AGY-Token-Tips-macos-arm64.zip) + 后台服务（[中文版](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-macos-arm64-zh-CN.zip) · [英文版](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-macos-arm64-en.zip)）

| 平台 | 下载后台服务 | 首次安装 | 日常启动 Antigravity |
| --- | --- | --- | --- |
| Windows x64 | [中文版](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-windows-x64-zh-CN.zip) · [英文版](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-windows-x64-en.zip) | 双击 `install.cmd` | 双击 `start-antigravity.cmd` |
| Linux x64 | [中文版](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-linux-x64-zh-CN.zip) · [英文版](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-linux-x64-en.zip) | 运行 `bash install.sh` | 运行 `bash start-antigravity.sh` |

![旧版输入框嵌入样式预览](assets/agy-preview.png)

<details>
<summary>技术原理、隐私说明与旧版脚本管理</summary>

### 原生 macOS HUD 技术与隐私说明
- **严格只读 SQLite**：仅以 `SQLITE_OPEN_READONLY` + `PRAGMA query_only = ON` 按文件变更缓存只读 `~/.gemini/antigravity/conversations/<uuid>.db`（`gen_metadata`）与 `conversation_summaries.db`，读取耗时 <2ms 并立即关闭连接，绝不锁库、绝不修改任何会话数据。
- **窗口吸附零权限**：通过 macOS 公开 `CGWindowListCopyWindowInfo` 读取 Antigravity 主窗口坐标，无需“辅助功能”或“屏幕录制”权限，不修改客户端安装包、不注入进程。
- **官方额度零泄露**：只调用官方 `agy --output-format json -p /usage`（单飞防重、20 秒超时保护、本地缓存至 `~/Library/Application Support/TokenLensHUD/quota-cache.json`），零 Token 消耗，不上传任何对话或凭据。

### 管理旧版后台服务

| 操作 | macOS | Windows | Linux |
| --- | --- | --- | --- |
| 中文解释 | `install-zh.command` | `install-zh.cmd` | `install-zh.sh` |
| 英文解释 | `install-en.command` | `install-en.cmd` | `install-en.sh` |
| 检查状态 | `status.command` | `status.cmd` | `status.sh` |
| 卸载 | `uninstall.command` | `uninstall.cmd` | `uninstall.sh` |

### 旧版 Node.js 源码开发（Node.js >=22.16）

```bash
bash start.sh start --language zh-CN
bash start.sh doctor
npm test
npm run demo
```

详见 [协议说明](docs/protocol.md)。

</details>

## 参与贡献

欢迎提 Issue / PR，共同改进兼容性、翻译与多平台体验，详见 [贡献指南](CONTRIBUTING.md)。

灵感来自 [船板的 Antigravity 补丁](https://github.com/Anarcadia/chuanban-antigravity-theme-patch)。本项目独立实现，采用 [MIT 许可](LICENSE)，非 Google 官方项目。
