---
id: development
title: 開發
---

# 開發

這個儲存庫是一個 Cargo 工作區，外加三個宿主。以下內容都假設你已取得 [cfoust/antiphon](https://github.com/cfoust/antiphon) 的簽出副本。

## 目錄結構

```
crates/
  antiphon-assets   .antiphon binary format + zero-dep no_std reader
  antiphon-dsp      the engine: HRTF, ITD, reflections, reverb (no I/O, no threads)
  antiphon-ffi      the single C ABI for both hosts (staticlib + wasm32 cdylib)
  antiphon-pose     6DoF head-pose solver (native tracker)
  antiphon-bake     offline: HRTF model + room presets -> .antiphon asset
  antiphon-render   offline: scene -> stereo WAV; the listening + parity oracle
native/AntiphonApp  SwiftUI host (swiftc only — no Xcode project)
antiphond/          Go daemon: agent registry, TTS ladder, WS hub
plugins/            per-agent adapters (claude-code, codex, opencode, pi, aider)
web/                marketing site + web demo (Vite/Bun + AudioWorklet)
docs-site/          this documentation (Docusaurus)
```

## 常用工作

各種配方都收在最上層的 `justfile`：

```bash
just bake     # 一次性：烘焙 HRTF 與房間資產
just render   # 離線示範渲染 -> out/*.wav（請戴上耳機聆聽！）
just test     # cargo test --release
just parity   # 原生/wasm 一致性關卡——任何 dsp/ffi 改動後都必須跑
just app      # 建置原生應用程式（內含 antiphond）
just serve    # 行銷網站 + 網頁展示的開發伺服器
just tag      # 發布一個 CalVer 版本標籤
```

工具鏈：Rust stable 加上 `wasm32-unknown-unknown`、Go ≥ 1.21、Xcode Command Line Tools、[Bun](https://bun.sh)、[just](https://github.com/casey/just)，以及供 Python 產生器腳本使用的 `uv`。

## 兩條不變式

1. **原生↔wasm 一致性。** 對 `antiphon-dsp` 或 `antiphon-ffi` 的任何改動，都必須讓 `just parity` 持續通過（誤差 < −90 dBFS；實際大約落在 −155）。避免與平台相關的浮點行為、執行緒，以及熱路徑上的記憶體配置。
2. **單一座標系。** 幾何由 DSP crate 全權掌管（右手座標系，前方 = −z，方位角朝 +左）。宿主在各自的邊界處轉換。動到任何與姿態或 ITD 相關的程式碼之前，請先閱讀儲存庫裡的 `docs/conventions.md`——ITD 的正負號只要用猜的，左右就會顛倒。

## 品質關卡是你的耳朵

這裡沒有自動化的知覺測試。任何聽得見的改動之後，請重新產生離線渲染，戴上耳機聆聽。如果你聽不出差別，那也是一項發現——請在 PR 裡如實說明。
