---
tags: middleware, agent, lifecycle, interceptor, comparison
---

# LangChain Middleware vs Pi 执行管线对比

> **范围**：对比 LangChain v1 `AgentMiddleware` 系统与 Pi 的多层执行管线（Agent Loop 回调 + AgentEvent + Harness/Extension Hook），分析 Middleware 模式在 Pi 中的等价实现
>
> **综合自**：langchain v1, pi-mono (agent + agent-harness + coding-agent)
>
> **优先级**：P1

本笔记对 LangChain v1 Middleware 系统与 Pi 的多层执行管线做了深度对比，覆盖：

- 架构模型：统一的 Middleware 类 + 图节点编排 vs 职责分离的三层架构
- 拦截能力：`before_model` / `after_model` / `wrap_model_call` / `wrap_tool_call` 的实现差异
- 完整对比矩阵（生命周期钩子、拦截器、工具/状态注册、异步模型、错误处理、类型安全等 8 个维度）
- 同一功能在两种系统中的代码示例（重试、危险工具阻断、消息上下文裁剪）
- 设计哲学对比与最佳实践

下方内嵌的 HTML 是本笔记的视觉设计稿（含 TsangerJinKai02 字体、对比表、决策矩阵、代码示例的排版），可滚动展示：

<iframe
  src="/learns/agent/langchain-middleware-vs-pi.html"
  width="100%"
  height="2400"
  style="border: 0; min-height: 80vh;"
  loading="lazy"
  title="LangChain Middleware vs Pi 执行管线对比"
></iframe>

[在新窗口打开完整设计稿 →](/learns/agent/langchain-middleware-vs-pi.html)

---

## 相关文档

- [Agent Hook 系统对比：Pi vs LangChain](/learns/agent/hook-system-comparison) —— Pi 三层 Hook 架构与 LC 旧版 Callback 系统的对比
- [Pi Hook & ReAct Loop 架构](/learns/agent/pi-hook-react-loop-architecture) —— Pi 的 ReAct 循环执行流程详解
- [LangChain Callback 系统](/learns/agent/langchain-callback-system) —— LC 旧版 Callback（Mixin-Based）的详细分析

---

## 参考

- [LangChain v1 Middleware 源码](https://github.com/langchain-ai/langchain/blob/master/libs/langchain_v1/langchain/agents/middleware/types.py)
- [LangChain create_agent 集成点](https://github.com/langchain-ai/langchain/blob/master/libs/langchain_v1/langchain/agents/factory.py)
- [Pi Agent 源码](https://github.com/earendil-works/pi-mono/blob/main/packages/agent/src/agent.ts)
- [Pi Agent Loop 源码](https://github.com/earendil-works/pi-mono/blob/main/packages/agent/src/agent-loop.ts)
- [Pi Extension Runner 源码](https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/src/core/extensions/runner.ts)

---

*创建时间：2026-06-04*
*更新时间：2026-06-04*
