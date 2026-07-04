---
id: claude-code
title: Claude Code
---

# Claude Code

参考集成，也是保真度最高的一个：身份绑定、工具滴答、由 LLM 撰写的叙述、语音总结、阻塞通知，以及从房间回传到会话的对话。

## 安装

```bash
claude plugin marketplace add cfoust/antiphon
claude plugin install antiphon@antiphon
```

就这么简单。插件会自动定位 `antiphond`（它打包在 `Antiphon.app` 里），并在你的下一个会话开始叙述。

## 工作原理

- 一个 MCP 服务器（`antiphond channel`）为模型提供四个工具——`antiphon_task`、`antiphon_progress`、`antiphon_done`、`antiphon_blocked`——会话启动钩子会注入一段简短的指令，要求模型通过它们把思路说出来。你听到的叙述是模型在工作时亲自撰写的。
- 一个 `PostToolUse` 钩子在每次工具调用时发出即发即忘的滴答——这就是那串和弦。
- 你从房间里发送的消息，会作为用户输入抵达会话。

## 基于本地检出开发

```bash
claude --plugin-dir /path/to/antiphon/plugins/claude-code
```

如果你在修改守护进程本身，可将 `ANTIPHOND` 指向特定的守护进程二进制文件。
