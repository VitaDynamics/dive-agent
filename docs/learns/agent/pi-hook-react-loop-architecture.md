---
tags: pi-mono, hook, agent, react-loop, architecture
---

# Pi Agent 三层 Hook 系统架构

> **范围**：拆解 Pi（pi-mono）Agent Loop 内三层 Hook 系统的分层职责——`AgentLoopConfig` 生命周期回调、`AgentEvent` 事件流订阅、Harness/Extension 层的 `HookEvent` + `ExtensionRunner` 拦截器，并画出它们与对应外部系统的等价关系
>
> **呈现形式**：本笔记的设计稿保留为独立 HTML 资源，下方内嵌可滚动展示

Pi 没有"Middleware"这个统一抽象，而是把扩展点按层次拆成三套独立系统：

1. **Agent Loop 层**（`AgentLoopConfig` 回调）—— 等价于 LangChain 的生命周期钩子（`before_model` / `after_model`）
2. **Agent Event 层**（`AgentEvent` 流 + `subscribe()`）—— 等价于 LangChain 旧版 `BaseCallbackHandler`（纯观测）
3. **Harness/Extension 层**（`HookEvent` + `ExtensionRunner`）—— 等价于 LangChain 的 `wrap_model_call` / `wrap_tool_call` 拦截器 + 工具注册

下方内嵌的 HTML 是本笔记的视觉设计稿，包含完整的三层时序图、事件订阅时序、Extension 注册流程，以及与 LangChain v1 Middleware 的能力对照矩阵：

<iframe
  src="./pi-hook-react-loop-architecture.html"
  width="100%"
  height="2400"
  style="border: 0; min-height: 80vh;"
  loading="lazy"
  title="Pi Agent 三层 Hook 系统架构"
></iframe>

[在新窗口打开完整设计稿 →](./pi-hook-react-loop-architecture.html)
