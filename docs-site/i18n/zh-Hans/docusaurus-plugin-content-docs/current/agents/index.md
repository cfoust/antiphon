---
id: index
title: 接入智能体
---

# 接入智能体

Antiphon 通过与本地 `antiphond` 守护进程通信的小型适配器来聆听智能体会话。每个适配器都是**故障即放行（fail-open）**的：如果 Antiphon 未安装或未运行，你的智能体的行为与插件不存在时完全一致。会话绝不会因守护进程而阻塞。

## 适配器上报什么

| 事件 | 你会听到 |
| --- | --- |
| 会话开始 | 智能体在房间里入座 |
| 工具调用 | 该智能体和弦中的一个音 |
| 叙述 | 简短的第一人称进度播报，以语音说出 |
| 完成 | 一两句总结，从它的座位上说出 |
| 阻塞 / 需要你 | 一侧耳畔缓缓积起的等待之花 |

保真度取决于各个智能体的扩展 API 暴露了什么——各页面均列出了确切的支持矩阵。

## 目前支持

- [Claude Code](./claude-code.md)——参考集成
- [Codex CLI](./codex.md)
- [OpenCode](./opencode.md)
- [Pi](./pi.md)
- [Aider](./aider.md)

## 你的智能体也可以

协议刻意保持精简：一个连接到 `127.0.0.1` 的 WebSocket（`/agent`），或通过 `antiphond emit` 发送一次性事件。读一读 [`plugins/`](https://github.com/cfoust/antiphon/tree/main/plugins) 里的任意一个适配器——最小的只有一个文件。欢迎提 PR。
