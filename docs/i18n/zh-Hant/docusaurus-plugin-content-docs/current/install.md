---
id: install
title: 安裝
---

# 安裝

Antiphon 在 macOS（Apple Silicon）上執行。應用程式內建了一切所需：渲染引擎、`antiphond` 常駐程式，以及烘焙好的 HRTF 資產。

## 下載應用程式

取得最新版本：

**[下載 macOS 版 Antiphon](https://github.com/cfoust/antiphon/releases/latest)**——下載 `Antiphon-<版本>-macOS.zip`。

解壓縮後，將 `Antiphon.app` 拖進 `/Applications`。發行版均已用 Apple Developer ID 簽署並完成公證——像打開任何應用程式一樣打開即可。

首次啟動時，應用程式會引導你選擇攝影機、完成十秒鐘的校正，以及一段針對你耳朵的貼合調整。請戴上耳機——整個產品都是雙耳（binaural）渲染。

## 接上代理

應用程式負責渲染房間；住進房間的，則是你的程式代理（coding agent）。為你使用的代理安裝對應的轉接器——[Claude Code、Codex、OpenCode、Pi 或 Aider](./agents/index.md)——每一個都只需一行指令或一份設定檔。轉接器會自動找到常駐程式（它就住在 `Antiphon.app` 裡），而且全都是 fail-open：如果 Antiphon 沒有在執行，你的代理的行為就跟沒裝外掛時一模一樣。

## 語音

開箱即用時，旁白採用內建的 macOS 語音——免費、離線、夠用。想要好得多的聲音，請在應用程式中開啟 **設定 → 語音**，加入 [ElevenLabs](https://elevenlabs.io) 或 [OpenAI](https://platform.openai.com) 的 API 金鑰。每個代理工作階段會從你啟用的供應商中，隨機獲派一個固定不變的語音；你也可以逐一開啟或關閉個別語音。

金鑰儲存在 `~/.antiphon/config.json`（權限 `0600`，僅存於本機），並且只能透過「設定」填寫——Antiphon 刻意忽略環境變數。

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

## 解除安裝

Antiphon 的一切都在兩個位置。結束應用程式後：

```bash
rm -rf /Applications/Antiphon.app
rm -rf ~/.antiphon   # 設定（含 API 金鑰）、代理註冊表、TTS 快取、紀錄
```

如果安裝過代理轉接器，刪除你加入過的那些：

```bash
claude plugin uninstall antiphon@antiphon        # Claude Code
rm ~/.config/opencode/plugins/antiphon.ts         # OpenCode
rm ~/.pi/agent/extensions/antiphon.ts             # Pi
rm -rf ~/.codex/antiphon                          # Codex（另需刪除 ~/.codex/hooks.json
                                                  # 裡的 antiphon 項目和 config.toml
                                                  # 裡的相應設定區塊）
```
