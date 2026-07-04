---
id: development
title: 开发
---

# 开发

仓库是一个 Cargo workspace 加三个宿主。以下内容均假设你已检出 [cfoust/antiphon](https://github.com/cfoust/antiphon)。

## 目录结构

```
crates/
  antiphon-assets   .antiphon 二进制格式 + 零依赖 no_std 读取器
  antiphon-dsp      引擎：HRTF、ITD、反射、混响（无 I/O、无线程）
  antiphon-ffi      两个宿主共用的唯一 C ABI（staticlib + wasm32 cdylib）
  antiphon-pose     6DoF 头部姿态求解器（原生追踪器）
  antiphon-bake     离线：HRTF 模型 + 房间预设 -> .antiphon 资产
  antiphon-render   离线：场景 -> 立体声 WAV；试听 + 一致性基准
native/AntiphonApp  SwiftUI 宿主（仅用 swiftc——没有 Xcode 工程）
antiphond/          Go 守护进程：智能体注册表、TTS 阶梯、WS 中枢
plugins/            各智能体适配器（claude-code、codex、opencode、pi、aider）
web/                营销站 + 网页演示（Vite/Bun + AudioWorklet）
docs/          本文档（Docusaurus）
```

## 常用任务

配方都在顶层的 `justfile` 里：

```bash
just bake     # 一次性：烘焙 HRTF + 房间资产
just render   # 离线演示渲染 -> out/*.wav（戴耳机听！）
just test     # cargo test --release
just parity   # 原生/wasm 一致性关卡——任何 dsp/ffi 改动后必须运行
just app      # 构建原生应用（打包 antiphond）
just serve    # 营销站 + 网页演示开发服务器
just tag      # 发布一个 CalVer 版本标签
```

工具链：Rust stable 加 `wasm32-unknown-unknown`、Go ≥ 1.21、Xcode Command Line Tools、[Bun](https://bun.sh)、[just](https://github.com/casey/just)，以及运行 Python 生成脚本所需的 `uv`。

## 两条不变量

1. **原生↔wasm 一致性。**对 `antiphon-dsp` 或 `antiphon-ffi` 的任何改动都必须保证 `just parity` 通过（误差 < −90 dBFS；实际约在 −155）。避免依赖平台的浮点行为、线程，以及热路径上的内存分配。
2. **唯一坐标系。**DSP crate 拥有几何定义（右手系，正前方 = −z，方位角朝 +左）。宿主在各自的边界处转换。改动任何与姿态或 ITD 相关的代码之前，先阅读仓库中的 `docs/internal/conventions.md`——ITD 的符号一猜就会左右颠倒。

## 质量关卡是你的耳朵

没有自动化的感知测试。任何可听的改动之后，重新生成离线渲染并戴耳机听。如果你听不出差别，那也是一个发现——在 PR 里如实写明。
