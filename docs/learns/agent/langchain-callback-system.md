---
tags: langchain, callback, hook, agent, architecture
---

# LangChain Callback 系统架构

> **范围**：拆解 LangChain 0.x `BaseCallbackHandler` 的事件模型、`on_*` 钩子协议、`CallbackManager` 的多 handler 编排，以及它与 LangChain v1 `AgentMiddleware` 的演进关系
>
> **呈现形式**：本笔记的设计稿保留为独立 HTML 资源，下方内嵌可滚动展示

LangChain 0.x 的回调系统是一切"可观测性 + 轻量拦截"设计的鼻祖。它通过 `BaseCallbackHandler` 这个抽象基类提供一组 `on_llm_start` / `on_chain_end` / `on_tool_error` 这样的 `on_*` 钩子，让任何外部系统（日志、Tracing、监控）可以"挂"到 Agent 执行流水线上而不必修改框架核心。

下方内嵌的 HTML 是本笔记的视觉设计稿，包含完整的事件流时序图、`CallbackManager` 内部结构图、与 `AgentMiddleware` 的能力对照矩阵：

<iframe
  src="/learns/agent/langchain-callback-system.html"
  width="100%"
  height="2400"
  style="border: 0; min-height: 80vh;"
  loading="lazy"
  title="LangChain Callback 系统架构"
></iframe>

[在新窗口打开完整设计稿 →](/learns/agent/langchain-callback-system.html)
