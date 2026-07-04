---
id: opencode
title: OpenCode
---

# OpenCode

OpenCode 的行程內外掛 API，讓這個轉接器只憑一個零相依的 TypeScript 檔案就達到高保真度：即時的工作階段綁定與標題、工具滴答、透過註冊的 `antiphon_*` 工具由模型撰寫的旁白、一個會唸出最後一則助理訊息的閒置後援，以及來自權限事件的受阻提示。

## 安裝

```bash
cp plugins/opencode/index.ts ~/.config/opencode/plugins/antiphon.ts
```

安裝就這麼一步。（以 npm 套件形式發布、供 `opencode.json` 的 `plugin` 陣列使用已在規劃中；不論哪種方式，這個檔案的行為完全相同。）

## 你會得到什麼

- 在 `session.created` 時**綁定**——工作階段入座，標題取自你的提示。
- 每次 `tool.execute.after` 都有**工具滴答**。
- **旁白** — 轉接器會註冊四個 `antiphon_*` 工具，並把旁白指示注入系統提示，讓模型以第一人稱把想法說出來。
- **完成後援** — 如果模型沒有自行旁白，`session.idle` 會唸出最後一則助理訊息（並與模型主動呼叫的 `antiphon_done` 去重）。
- 在 `permission.asked` 時回報**受阻**。
- **回話（talk-back）** — 你從房間送出的訊息會經由 OpenCode SDK（盡力而為）送進工作階段，並以終端機窗格注入作為後備。

子代理的子工作階段保持沉默——只有你的頂層工作階段會獲得座位。
