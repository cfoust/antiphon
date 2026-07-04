---
id: claude-code
title: Claude Code
---

# Claude Code

參考實作，也是保真度最高的一個：身分綁定、工具滴答、由 LLM 撰寫的旁白、語音摘要、受阻通知，以及從房間回進工作階段的回話（talk-back）。

## 安裝

```bash
claude plugin marketplace add cfoust/antiphon
claude plugin install antiphon@antiphon
```

這樣就完成了。外掛會自動找到 `antiphond`（它隨附在 `Antiphon.app` 裡），並在你的下一個工作階段開始旁白。

## 運作方式

- 一個 MCP 伺服器（`antiphond channel`）提供模型四個工具——`antiphon_task`、`antiphon_progress`、`antiphon_done`、`antiphon_blocked`——並由工作階段開始時的 hook 注入一段簡短的指示，要模型透過這些工具把想法說出來。你聽到的旁白，是模型在工作當下親筆寫成的。
- 一個 `PostToolUse` hook 會在每次工具呼叫時發出一聲射後不理的滴答——那就是和弦。
- 你從房間送出的訊息，會以使用者輸入的形式進入工作階段。

## 以簽出的原始碼開發

```bash
claude --plugin-dir /path/to/antiphon/plugins/claude-code
```

如果你正在改常駐程式本身，可以設定 `ANTIPHOND` 指向特定的常駐程式執行檔。
