---
id: install
title: Установка
---

# Установка

Antiphon работает на macOS (Apple Silicon). В приложении есть всё необходимое: движок
рендеринга, демон `antiphond` и запечённые HRTF-ассеты.

## Скачайте приложение

Возьмите свежий релиз:

**[Скачать Antiphon для macOS](https://github.com/cfoust/antiphon/releases/latest/download/Antiphon-macOS.zip)**

Распакуйте архив и перетащите `Antiphon.app` в `/Applications`.

:::note Gatekeeper
Релизные сборки пока не нотаризованы под Apple Developer ID. При первом запуске macOS
вежливо откажет; снимите флаг карантина и откройте приложение:

```bash
xattr -d com.apple.quarantine /Applications/Antiphon.app
open /Applications/Antiphon.app
```
:::

При первом запуске приложение проведёт вас через выбор камеры, десятисекундную калибровку
и подстройку под ваши уши. Наденьте наушники — весь продукт бинауральный.

## Подключите агента

Приложение рендерит комнату; населяют её ваши кодинг-агенты. Установите адаптер для того,
чем вы пользуетесь, — [Claude Code, Codex, OpenCode, Pi или Aider](./agents/index.md) —
каждый ставится одной командой или одним конфигурационным файлом. Адаптеры находят демон
автоматически (он живёт внутри `Antiphon.app`) и работают по принципу fail-open: если
Antiphon не запущен, агент ведёт себя ровно так, как будто плагин не установлен.

## Голоса

Из коробки озвучка использует встроенные голоса macOS — бесплатно, офлайн и вполне
прилично. Ради голосов заметно лучше откройте **Настройки → Голоса** в приложении и
добавьте API-ключ [ElevenLabs](https://elevenlabs.io) или
[OpenAI](https://platform.openai.com). Каждой сессии агента случайным образом назначается
постоянный голос из включённых вами провайдеров; отдельные голоса можно включать и
выключать.

Ключи хранятся в `~/.antiphon/config.json` (права `0600`, только локально). Переменные
окружения `ELEVENLABS_API_KEY` и `OPENAI_API_KEY` работают как запасной вариант.

## Homebrew

Tap запланирован (`cfoust/homebrew-taps`), но пока не выпущен — а до тех пор пользуйтесь
zip-архивом выше или [соберите из исходников](./development.md).

## Сборка из исходников

```bash
git clone https://github.com/cfoust/antiphon
cd antiphon
cargo run -p antiphon-bake --release -- assets/baked/antiphon-default.antiphon
bash native/AntiphonApp/make.sh
open native/AntiphonApp/Antiphon.app
```

Требования: Rust (stable), Go 1.21+ и Xcode Command Line Tools (`swiftc`) — без Xcode и
без SwiftPM. Подробности — в разделе [Разработка](./development.md).
