---
id: opencode
title: OpenCode
---

# OpenCode

OpenCode 的进程内插件 API 让这个适配器仅凭一个零依赖的 TypeScript 文件就达到了很高的保真度：带标题的实时会话绑定、工具滴答、通过注册的 `antiphon_*` 工具实现的模型撰写叙述、在空闲时播出最后一条助手消息的兜底机制，以及来自权限事件的阻塞提醒。

## 安装

```bash
cp plugins/opencode/index.ts ~/.config/opencode/plugins/antiphon.ts
```

安装到此为止。（计划发布为 npm 包以配合 `opencode.json` 的 `plugin` 数组；无论哪种方式，这个文件的行为完全相同。）

## 你能得到什么

- 在 `session.created` 时**绑定**——会话入座，标题取自你的提示词。
- 每次 `tool.execute.after` 触发**工具滴答**。
- **叙述**——适配器注册四个 `antiphon_*` 工具，并把叙述指令注入系统提示词，让模型以第一人称把思路说出来。
- **完成兜底**——如果模型没有亲自叙述，`session.idle` 会播出最后一条助手消息（并与模型主动调用的 `antiphon_done` 去重）。
- 在 `permission.asked` 时触发**阻塞**。
- **对话回传**——你从房间里发送的消息经由 OpenCode SDK 送入会话（尽力而为），失败时退回终端窗格注入。

子智能体的子会话保持静默——只有你的顶层会话才会获得座位。
