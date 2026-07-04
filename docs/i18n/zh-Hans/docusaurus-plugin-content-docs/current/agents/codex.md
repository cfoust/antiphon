---
id: codex
title: Codex CLI
---

# Codex CLI

Codex 的钩子引擎与 Claude Code 的形态几乎相同，因此这个适配器接近 1:1 的移植：工具滴答、通过 MCP 的模型撰写叙述、带 Stop 钩子兜底的语音总结，以及来自权限请求的阻塞通知。

## 安装

```bash
sh plugins/codex/install.sh
```

安装器会以幂等方式合并进 `~/.codex/`（已有钩子会被保留，备份带时间戳）：`hooks.json` 中的钩子条目、`config.toml` 中的 MCP 服务器配置块，以及位于 `~/.codex/antiphon/` 下的适配器脚本。然后在 Codex 内运行一次 `/hooks` 以信任新钩子。

## 你能得到什么

- **会话开始**时注入叙述指令，让模型在工作时调用 `antiphon_task` / `antiphon_progress` / `antiphon_done` / `antiphon_blocked`。
- **每次工具调用**都会拨响该智能体的和弦（`PostToolUse` → `antiphond emit`）。
- **Stop** 在模型没有亲自叙述时，把最后一条助手消息作为语音总结播出。
- **权限请求**会以请求描述奏响等待之花。

## 已知的小毛病

- Codex 不向 MCP 子进程暴露会话 id，所以一个 Codex 会话可能表现为**两条注册记录**（叙述通道与钩子事件各一条）。纯属外观问题——两者都会从房间里发声——但值得知道。
- 从房间回传到 Codex 的对话，仅能通过终端窗格注入（tmux）实现。

一切都是故障即放行的：Antiphon 不在运行时，Codex 的行为与什么都没装一样。
