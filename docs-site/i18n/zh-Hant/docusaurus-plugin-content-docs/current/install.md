---
id: install
title: 安裝
---

# 安裝

Antiphon 在 macOS（Apple Silicon）上執行。應用程式內建了一切所需：渲染引擎、`antiphond` 常駐程式，以及烘焙好的 HRTF 資產。

## 下載應用程式

取得最新版本：

**[下載 macOS 版 Antiphon](https://github.com/cfoust/antiphon/releases/latest/download/Antiphon-macOS.zip)**

解壓縮後，將 `Antiphon.app` 拖進 `/Applications`。

:::note Gatekeeper
釋出的版本尚未以 Apple Developer ID 完成公證。第一次啟動時，macOS 會客氣地拒絕你；清除隔離旗標後再開啟即可：

```bash
xattr -d com.apple.quarantine /Applications/Antiphon.app
open /Applications/Antiphon.app
```
:::

首次啟動時，應用程式會引導你選擇攝影機、完成十秒鐘的校正，以及一段針對你耳朵的貼合調整。請戴上耳機——整個產品都是雙耳（binaural）渲染。

## 接上代理

應用程式負責渲染房間；住進房間的，則是你的程式代理（coding agent）。為你使用的代理安裝對應的轉接器——[Claude Code、Codex、OpenCode、Pi 或 Aider](./agents/index.md)——每一個都只需一行指令或一份設定檔。轉接器會自動找到常駐程式（它就住在 `Antiphon.app` 裡），而且全都是 fail-open：如果 Antiphon 沒有在執行，你的代理的行為就跟沒裝外掛時一模一樣。

## 語音

開箱即用時，旁白採用內建的 macOS 語音——免費、離線、夠用。想要好得多的聲音，請在應用程式中開啟 **設定 → 語音**，加入 [ElevenLabs](https://elevenlabs.io) 或 [OpenAI](https://platform.openai.com) 的 API 金鑰。每個代理工作階段會從你啟用的供應商中，隨機獲派一個固定不變的語音；你也可以逐一開啟或關閉個別語音。

金鑰儲存在 `~/.antiphon/config.json`（權限 `0600`，僅存於本機）。環境變數 `ELEVENLABS_API_KEY` 與 `OPENAI_API_KEY` 可作為後備。

## Homebrew

Homebrew tap 已在規劃中（`cfoust/homebrew-taps`），但尚未推出——目前請使用上面的 zip，或[從原始碼建置](./development.md)。

## 從原始碼建置

```bash
git clone https://github.com/cfoust/antiphon
cd antiphon
cargo run -p antiphon-bake --release -- assets/baked/antiphon-default.antiphon
bash native/AntiphonApp/make.sh
open native/AntiphonApp/Antiphon.app
```

需求：Rust（stable）、Go 1.21+，以及 Xcode Command Line Tools（`swiftc`）——不需要 Xcode，也不需要 SwiftPM。詳見[開發](./development.md)。
