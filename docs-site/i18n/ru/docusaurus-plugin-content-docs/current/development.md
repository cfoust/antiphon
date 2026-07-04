---
id: development
title: Разработка
---

# Разработка

Репозиторий — это Cargo-workspace плюс три хоста. Всё, что ниже, предполагает клон
[cfoust/antiphon](https://github.com/cfoust/antiphon).

## Структура

```
crates/
  antiphon-assets   бинарный формат .antiphon + no_std-ридер без зависимостей
  antiphon-dsp      движок: HRTF, ITD, отражения, реверберация (без I/O, без потоков)
  antiphon-ffi      единый C ABI для обоих хостов (staticlib + wasm32 cdylib)
  antiphon-pose     6DoF-решатель позы головы (нативный трекер)
  antiphon-bake     офлайн: модель HRTF + пресеты комнат -> ассет .antiphon
  antiphon-render   офлайн: сцена -> стерео-WAV; оракул прослушивания и паритета
native/AntiphonApp  SwiftUI-хост (только swiftc — без проекта Xcode)
antiphond/          Go-демон: реестр агентов, лестница TTS, WS-хаб
plugins/            адаптеры для агентов (claude-code, codex, opencode, pi, aider)
web/                маркетинговый сайт + веб-демо (Vite/Bun + AudioWorklet)
docs-site/          эта документация (Docusaurus)
```

## Типовые задачи

Рецепты живут в корневом `justfile`:

```bash
just bake     # однократно: запечь ассет HRTF + комнаты
just render   # офлайн-рендеры демо -> out/*.wav (слушайте в наушниках!)
just test     # cargo test --release
just parity   # порог паритета native/wasm — запускать после ЛЮБОГО изменения dsp/ffi
just app      # собрать нативное приложение (включает antiphond)
just serve    # dev-сервер маркетингового сайта + веб-демо
just tag      # выпустить релизный CalVer-тег
```

Тулчейн: Rust stable с `wasm32-unknown-unknown`, Go ≥ 1.21, Xcode Command Line Tools,
[Bun](https://bun.sh), [just](https://github.com/casey/just) и `uv` для генераторных
Python-скриптов.

## Два инварианта

1. **Паритет native↔wasm.** Любое изменение в `antiphon-dsp` или `antiphon-ffi` должно
   оставлять `just parity` зелёным (ошибка < −90 dBFS; на деле она держится около −155).
   Избегайте платформозависимого поведения чисел с плавающей точкой, потоков и аллокаций
   на горячем пути.
2. **Одна система координат.** Геометрией владеет DSP-крейт (правая система, фронт = −z,
   азимут — в сторону +left). Хосты конвертируют на своей границе. Прочитайте
   `docs/conventions.md` в репозитории, прежде чем трогать что-либо связанное с позой или
   ITD, — если действовать наугад, знак ITD меняет левое и правое местами.

## Порог качества — ваши уши

Автоматического перцептивного теста нет. После любого слышимого изменения перегенерируйте
офлайн-рендеры и послушайте в наушниках. Если разницы не слышно — это тоже результат;
так и напишите в PR.
