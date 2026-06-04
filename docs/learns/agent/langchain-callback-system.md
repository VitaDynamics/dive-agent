---
tags: langchain, callback, hook, agent, architecture
---

# LangChain Callback 系统架构

> **范围**：拆解 LangChain 0.x `BaseCallbackHandler` 的事件模型、`on_*` 钩子协议、`CallbackManager` 的多 handler 编排，以及它与 LangChain v1 `AgentMiddleware` 的演进关系
>
> **呈现形式**：本笔记的设计稿保留为独立 HTML 资源，下方内嵌可滚动展示

LangChain 0.x 的回调系统是一切"可观测性 + 轻量拦截"设计的鼻祖。它通过 `BaseCallbackHandler` 这个抽象基类提供一组 `on_llm_start` / `on_chain_end` / `on_tool_error` 这样的 `on_*` 钩子，让任何外部系统（日志、Tracing、监控）可以"挂"到 Agent 执行流水线上而不必修改框架核心。

本笔记的完整视觉设计稿（含事件流时序图、`CallbackManager` 内部结构图、与 `AgentMiddleware` 的能力对照矩阵）请全屏查看：

<a href="/dive-agent/designs/agent/langchain-callback-system.html" target="_blank" rel="noopener noreferrer">📄 全屏查看完整设计稿 →</a>
