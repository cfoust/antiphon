---
id: pi
title: Pi
---

# Pi

Pi 的擴充 API 是這幾家之中最完整的——這個轉接器達到與 Claude Code 完全同級的保真度，包括貨真價實的回話（talk-back）：你從房間送出的訊息，會經由 `pi.sendUserMessage` 以真正的使用者訊息形式進入工作階段。

## 安裝

```bash
cp plugins/pi/index.ts ~/.pi/agent/extensions/antiphon.ts
```

可用 `/reload` 熱重載。

## 你會得到什麼

- 在 `session_start` 時**綁定**，標題會即時更新。
- 在 `tool_execution_start` 時**工具滴答**。
- **旁白** — 轉接器把 `antiphon_task` / `antiphon_progress` / `antiphon_done` / `antiphon_blocked` 註冊為原生工具，並把旁白指示附加到系統提示。
- **完成後援** — 當模型沒有自行旁白總結時，`agent_end` 會唸出最終的助理訊息。
- **貨真價實的回話** — 中樞（hub）的通道訊框會成為工作階段裡的使用者訊息，並標記為 `<channel source="antiphon">`，所以你可以在房間裡回答某個代理，它會立刻據此行動。

唯一的限制：Pi 沒有向擴充功能開放權限請求事件，因此受阻提示只會在模型自己呼叫 `antiphon_blocked` 時出現。
