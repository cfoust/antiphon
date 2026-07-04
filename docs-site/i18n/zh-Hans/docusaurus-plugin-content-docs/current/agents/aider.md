---
id: aider
title: Aider
---

# Aider

Aider 没有插件系统——只有一条通知命令，在 LLM 结束并等待输入时触发，且不携带任何负载。因此这个适配器是一个启动包装器，保真度有限但诚实：在房间里有一席之地，外加 Aider 需要你时的一声轻推。

## 安装

```bash
cp plugins/aider/antiphon-aider ~/bin/ && chmod +x ~/bin/antiphon-aider
antiphon-aider  # 代替 `aider`，参数相同
```

## 你能得到什么

- 包装器启动时**绑定**——会话入座。
- **"等你回复"**——Aider 的通知被映射为阻塞之花。由于 Aider 无法区分*完成*与*等待批准*，每次轮次结束都会轻推你一下；这是 API 的天花板，不是缺陷。
- 包装器退出时报告**完成**（退出码原样保留）。

没有工具滴答，没有模型撰写的叙述，对话回传仅能通过终端窗格注入。如果 `aider` 没有被 Antiphon 包装，或者守护进程没在运行，包装器会直接 `exec` aider——零开销。
