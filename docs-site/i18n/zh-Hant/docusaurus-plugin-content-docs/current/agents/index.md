---
id: index
title: 接上程式代理
---

# 接上程式代理

Antiphon 透過小巧的轉接器聆聽代理工作階段，這些轉接器與本機的 `antiphond` 常駐程式溝通。每個轉接器都是 **fail-open**：如果沒有安裝或沒有執行 Antiphon，你的代理的行為就跟外掛不存在時一模一樣。工作階段永遠不會因為常駐程式而被卡住。

## 轉接器會回報什麼

| 事件 | 你會聽到 |
| --- | --- |
| 工作階段開始 | 代理在房間裡入座 |
| 工具呼叫 | 該代理和弦中的一個音 |
| 旁白 | 簡短的第一人稱進度，親口說出 |
| 完成 | 一兩句摘要，從它的座位說出 |
| 受阻／需要你 | 你一側耳中緩慢的等待綻放 |

保真度取決於各代理的擴充 API 開放了什麼——各頁面都附有確切的支援矩陣。

## 目前支援

- [Claude Code](./claude-code.md) — 參考實作
- [Codex CLI](./codex.md)
- [OpenCode](./opencode.md)
- [Pi](./pi.md)
- [Aider](./aider.md)

## 你的代理也可以

協定刻意保持精簡：一條連到 `127.0.0.1` 的 WebSocket（`/agent`），或透過 `antiphond emit` 送出的單發事件。讀讀 [`plugins/`](https://github.com/cfoust/antiphon/tree/main/plugins) 裡任何一個轉接器——最小的只有一個檔案。歡迎 PR。
