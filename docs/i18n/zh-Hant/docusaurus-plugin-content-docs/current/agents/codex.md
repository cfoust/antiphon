---
id: codex
title: Codex CLI
---

# Codex CLI

Codex 的 hooks 機制與 Claude Code 的形狀幾乎相同，因此這個轉接器接近 1:1 的移植：工具滴答、透過 MCP 由模型撰寫的旁白、附 Stop hook 後援的語音摘要，以及來自權限請求的受阻通知。

## 安裝

```bash
sh plugins/codex/install.sh
```

安裝程式會以冪等方式合併進 `~/.codex/`（既有的 hooks 會保留，備份會加上時間戳記）：`hooks.json` 裡的 hook 項目、`config.toml` 裡的 MCP 伺服器區塊，以及 `~/.codex/antiphon/` 底下的轉接器腳本。接著在 Codex 裡執行一次 `/hooks`，信任新加入的 hooks。

## 你會得到什麼

- **工作階段開始**時注入旁白指示，模型便會在工作過程中呼叫 `antiphon_task` / `antiphon_progress` / `antiphon_done` / `antiphon_blocked`。
- **每次工具呼叫**都會撥響該代理的和弦（`PostToolUse` → `antiphond emit`）。
- **Stop** 時，若模型沒有自行旁白，會把最後一則助理訊息作為語音摘要唸出。
- **權限請求**會帶著請求的描述，響起等待綻放。

## 已知怪癖

- Codex 不會把工作階段 id 提供給 MCP 子行程，因此一個 Codex 工作階段可能會以**兩筆註冊紀錄**出現（旁白通道與 hook 發出的事件各一筆）。純屬外觀問題——兩者都會從房間裡發聲——但值得知道。
- 從房間回到 Codex 的回話（talk-back），只能透過終端機窗格注入（tmux）。

一切都是 fail-open：Antiphon 沒有執行時，Codex 的行為就像什麼都沒裝一樣。
