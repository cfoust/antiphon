---
id: aider
title: Aider
---

# Aider

Aider 沒有外掛系統——只有一個通知指令，會在 LLM 完成並等待輸入時觸發，且不帶任何內容。因此這個轉接器是一個啟動包裝器，保真度有限但誠實：在房間裡的存在感，以及 Aider 需要你時的一聲輕推。

## 安裝

```bash
cp plugins/aider/antiphon-aider ~/bin/ && chmod +x ~/bin/antiphon-aider
antiphon-aider  # 取代 `aider`，參數相同
```

## 你會得到什麼

- 包裝器啟動時**綁定**——工作階段入座。
- **「等你回應」** — Aider 的通知被對應到受阻綻放。由於 Aider 無法區分*完成*與*等待核准*，每一輪結束它都會輕推你一下；那是 API 的天花板，不是臭蟲。
- 包裝器結束時回報**完成**（結束代碼原樣保留）。

沒有工具滴答，沒有模型撰寫的旁白，回話（talk-back）只能透過終端機窗格注入。如果 `aider` 沒有被 Antiphon 包裝，或常駐程式沒有在執行，包裝器會直接 `exec` aider——零成本。
