---
tags: agent, hook, middleware, callback, comparison
---

# Agent Hook 系统对比

> **范围**：对比 LangChain v1 Middleware、LangChain 旧版 Callback、Pi 三层 Hook、Kameo Actor 监督钩子、Kosong 事件订阅等 Agent 框架的"扩展点"机制，分析各家的能力边界与设计取舍
>
> **呈现形式**：本笔记的设计稿（含 TsangerJinKai02 字体、并列对照表、决策矩阵）保留为独立 HTML 资源，下方内嵌可滚动展示

本笔记对 Agent 框架的钩子/Middleware/订阅机制做了横向对比，覆盖以下 8 个维度的差异：

- 触发时机（同步 / 异步 / 流式事件）
- 拦截能力（只读观测 vs. 可改写 vs. 可阻断）
- 注册方式（装饰器 / 类继承 / 全局订阅）
- 异步模型（回调链 / 事件流 / Actor 消息）
- 错误处理（向上抛 vs. 局部吞 vs. 监督策略）
- 类型安全（动态 vs. 强类型）
- 与工具调用的耦合（独立 vs. 绑定 wrap_tool_call）
- 可观测性（结构化 trace / span / log）

下方内嵌的 HTML 是本笔记的视觉设计稿，包含完整的对比表、决策矩阵、流程图：

<iframe
  src="./hook-system-comparison.html"
  width="100%"
  height="2400"
  style="border: 0; min-height: 80vh;"
  loading="lazy"
  title="Agent Hook 系统对比"
></iframe>

[在新窗口打开完整设计稿 →](./hook-system-comparison.html)
