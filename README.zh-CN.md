# agy-token-tips

[English](README.md) | [简体中文](README.zh-CN.md)

用 **AGY Token Tips** 启动 Antigravity Desktop，就能在对话输入框旁看到 token 用量、上下文占用、生成速度和首字等待时间。

## macOS · Apple 芯片（M 系列）

**[下载 Mac 启动器（ZIP）](https://github.com/arShen6/agy-token-tips/raw/refs/heads/main/downloads/AGY-Token-Tips-macos-arm64.zip)**

1. **首次使用用量栏**，先装好 Antigravity Desktop，再下载后台服务（[中文提示版](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-macos-arm64-zh-CN.zip) / [英文提示版](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-macos-arm64-en.zip)）。完整解压，双击一次 `install.command`。已经装过后台服务的用户直接从第 2 步开始。
2. 解压上方的 **Mac 启动器**，把 `AGY-Token-Tips.app` 移到“应用程序”，再拖到 Dock。
3. **以后点 Dock 里的 AGY Token Tips 图标启动 Antigravity。** 打开对话发一条消息，首次模型调用完成后，输入框旁就会显示用量。

如果 Antigravity 已经打开，启动器提示需要重开，请先保存工作，再点“已保存，重新打开”。

## Windows 和 Linux · x64（实验版）

先装好 Antigravity Desktop，下载下表对应的压缩包，完整解压后运行一次安装脚本。首次通过启动脚本打开 Antigravity 前，请先保存工作并退出客户端。以后每次完全退出后，用同一个启动脚本打开即可。安装包已内置 Node.js。

| 平台 | 下载后台服务 | 首次安装 | 日常启动 Antigravity |
| --- | --- | --- | --- |
| Windows | [中文提示版](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-windows-x64-zh-CN.zip) · [英文提示版](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-windows-x64-en.zip) | 双击 `install.cmd` | 双击 `start-antigravity.cmd` |
| Linux | [中文提示版](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-linux-x64-zh-CN.zip) · [英文提示版](https://github.com/arShen6/agy-token-tips/releases/download/v0.2.5/agy-token-tips-0.2.5-linux-x64-en.zip) | 运行 `bash install.sh` | 运行 `bash start-antigravity.sh` |

请用普通用户在解压目录中运行脚本。Windows 需要任务计划程序及 Windows PowerShell，Linux 需要带用户级 systemd 的桌面会话。两个平台均已做基础自动化检查，客户端界面仍待实机验证。[反馈兼容性问题](https://github.com/arShen6/agy-token-tips/issues/new?template=bug_report.md)。

![agy-token-tips 在 Antigravity 中显示速度、等待时间、上下文用量和详细统计](assets/agy-preview.png)

*早期版本实机示例；当前详情已明确区分流式速度与端到端速度。*

## 可以看到什么

输入框旁直接看关键指标，鼠标悬停展开详情，无需打开其他面板。

| 指标 | 展示内容 |
| --- | --- |
| **Ctx** | 上下文已用 token / 上限与占比 |
| **tok/s** | 最近一次模型调用的输出速度 |
| **TTFT / Hold** | 首字等待 / 缓冲返回等待时间 |
| **Out** | 本次输出 token 数 |
| **悬停详情** | 思考与响应/工具输出、会话累计用量 |
| **缓存** | 缓存读取量与命中率 |

上下文占用达到 **75% 变黄、90% 变红**。底部统一英文缩写，详细解释可选中英文；数据可能在单次调用完成后更新。

## 管理后台服务

后台服务会在登录时自动运行。需要切换提示语言、检查状态或卸载时，运行安装包解压目录里的对应脚本。

| 操作 | macOS | Windows | Linux |
| --- | --- | --- | --- |
| 中文解释 | `install-zh.command` | `install-zh.cmd` | `install-zh.sh` |
| 英文解释 | `install-en.command` | `install-en.cmd` | `install-en.sh` |
| 检查状态 | `status.command` | `status.cmd` | `status.sh` |
| 卸载 | `uninstall.command` | `uninstall.cmd` | `uninstall.sh` |

安装器没有进行平台签名，首次运行可能需要系统或文件管理器确认。本次不提供 Windows ARM、Linux ARM、Intel Mac 的独立安装包。

## 理解这些数字

**流式速度不含等待，端到端速度包含等待。** 详情分别标注，并重复展示底部相同口径的速度；可能被缓冲的返回使用端到端速度和 `Hold` 标记。

数字来自本地用量数据，未知项显示 `—`，不按文本长度猜测 token；这些是会话指标，不代表账单或账户剩余额度。

<details>
<summary>技术说明、排查与开发</summary>

这是非官方的本地界面补丁，不是 VSIX 扩展。只读本地 `gen_metadata` 用量数据，通过本机调试连接添加提示条，不上传聊天或指标，不需要 API Key，也不修改应用安装包。

macOS 保留旧安装目录和服务标识：`~/Library/Application Support/AGY Metrics`。Windows 使用 `%LOCALAPPDATA%/agy-token-tips`；Linux 使用 `$XDG_DATA_HOME/agy-token-tips`，默认是 `~/.local/share/agy-token-tips`。安装器保存独立副本，之后可以移动下载目录。卸载会停止服务并移除登录启动项，保留日志和版本备份，不删除 Antigravity 会话。

无显示时先完成一次调用，再运行对应平台的状态脚本。`ready: true` 表示检查到了实际窗口中的组件。日志在安装目录的 `logs` 子目录；Linux 服务诊断可运行 `journalctl --user -u agy-token-tips.service -n 50`。客户端升级可能改变内部数据格式或界面属性；反馈时请附版本和脱敏错误，不要上传会话数据库。

从源码开发需要 Node.js >=22.16：

```bash
bash start.sh start --language zh-CN
bash start.sh doctor
npm test
npm run demo
```

预览使用模拟数据。Windows/Linux 仍属实验版；自动化测试和运行环境、启动脚本检查不等于客户端实机兼容性验收。详见 [协议说明](docs/protocol.md)。

</details>

## 参与贡献

欢迎提 Issue / PR，共同改进兼容性、翻译和安装体验，详见 [贡献指南](CONTRIBUTING.md)。其他客户端的适配需提供真实数据来源与实机验证。

灵感来自 [船板的 Antigravity 补丁](https://github.com/Anarcadia/chuanban-antigravity-theme-patch)。本项目独立实现，未包含该项目的代码或主题资源。采用 [MIT 许可](LICENSE)，非 Google 官方项目。内置 Node.js 使用其自身许可，见 `runtime/LICENSE`。
