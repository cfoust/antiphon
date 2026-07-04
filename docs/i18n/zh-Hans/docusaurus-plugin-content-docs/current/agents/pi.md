---
id: pi
title: Pi
---

# Pi

Pi 的扩展 API 是这一批里最完整的——这个适配器达到了与 Claude Code 完全对等的水平，包括货真价实的对话回传：你从房间里发送的消息，会经由 `pi.sendUserMessage` 以真正的用户消息形式抵达会话。

## 安装

```bash
cp plugins/pi/index.ts ~/.pi/agent/extensions/antiphon.ts
```

支持用 `/reload` 热重载。

## 你能得到什么

- 在 `session_start` 时**绑定**，带实时标题。
- 在 `tool_execution_start` 时触发**工具滴答**。
- **叙述**——适配器把 `antiphon_task` / `antiphon_progress` / `antiphon_done` / `antiphon_blocked` 注册为原生工具，并把叙述指令追加到系统提示词。
- **完成兜底**——当模型没有亲自总结时，`agent_end` 会播出最后一条助手消息。
- **真正的对话回传**——中枢的通道帧成为会话中的用户消息，标记为 `<channel source="antiphon">`，因此你可以从房间里回答一个智能体，它会立即照办。

一个限制：Pi 不向扩展暴露权限请求事件，所以阻塞提醒只在模型主动调用 `antiphon_blocked` 时才会发生。
