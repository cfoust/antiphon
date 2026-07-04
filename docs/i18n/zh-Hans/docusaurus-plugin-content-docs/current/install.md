---
id: install
title: 安装
---

# 安装

Antiphon 运行于 macOS（Apple Silicon）。应用打包了所需的一切：渲染引擎、`antiphond` 守护进程，以及预先烘焙好的 HRTF 资产。

## 下载应用

获取最新版本：

**[下载 macOS 版 Antiphon](https://github.com/cfoust/antiphon/releases/latest)**——下载 `Antiphon-<版本>-macOS.zip`。

解压后把 `Antiphon.app` 拖入 `/Applications`。发行版均已用 Apple Developer ID 签名并完成公证——像打开任何应用一样打开即可。

首次启动时，应用会引导你选择摄像头、完成十秒钟的校准，并针对你的耳朵调整适配。请戴上耳机——整个产品都是双耳（binaural）渲染的。

## 接入一个智能体

应用负责渲染房间；房间里的住客是你的编程智能体。为你在用的智能体安装对应的适配器——[Claude Code、Codex、OpenCode、Pi 或 Aider](./agents/index.md)——每个都只需一行命令或一个配置文件。适配器会自动找到守护进程（它就在 `Antiphon.app` 里面），并且是故障即放行（fail-open）的：如果 Antiphon 没在运行，你的智能体的行为与未安装插件时完全一致。

## 语音

开箱即用时，叙述使用 macOS 内置语音——免费、离线、够用。想要好得多的效果，请在应用中打开 **设置 → 语音**，添加 [ElevenLabs](https://elevenlabs.io) 或 [OpenAI](https://platform.openai.com) 的 API 密钥。每个智能体会话会从你启用的提供商中随机分配一个固定语音；单个语音可以逐一开关。

密钥存储在 `~/.antiphon/config.json`（权限 `0600`，仅限本机），并且只能通过"设置"填写——Antiphon 有意忽略环境变量。

## Homebrew

计划提供 tap（`cfoust/homebrew-taps`），但尚未发布——目前请使用上面的 zip，或[从源码构建](./development.md)。

## 从源码构建

```bash
git clone https://github.com/cfoust/antiphon
cd antiphon
cargo run -p antiphon-bake --release -- assets/baked/antiphon-default.antiphon
bash native/AntiphonApp/make.sh
open native/AntiphonApp/Antiphon.app
```

依赖：Rust（stable）、Go 1.21+，以及 Xcode Command Line Tools（`swiftc`）——不需要 Xcode，也不需要 SwiftPM。详见[开发](./development.md)。

## 卸载

Antiphon 的一切都在两个位置。退出应用后：

```bash
rm -rf /Applications/Antiphon.app
rm -rf ~/.antiphon   # 设置（含 API 密钥）、智能体注册表、TTS 缓存、日志
```

如果安装过智能体适配器，删除你添加过的那些：

```bash
claude plugin uninstall antiphon@antiphon        # Claude Code
rm ~/.config/opencode/plugins/antiphon.ts         # OpenCode
rm ~/.pi/agent/extensions/antiphon.ts             # Pi
rm -rf ~/.codex/antiphon                          # Codex（另需删除 ~/.codex/hooks.json
                                                  # 里的 antiphon 条目和 config.toml
                                                  # 里的相应配置块）
```
