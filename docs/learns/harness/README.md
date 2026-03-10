# Agent Harness 学习笔记

Agent 框架和编排工具的模式分析。

---

## 主题

### [流式处理](./streaming/)

异步流式、WebSocket 模式和实时通信。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [异步流式一等公民](./streaming/async-streaming-first-class.md) | 流式作为核心抽象：StreamedMessage 协议、Pull/Push/Hybrid 模式 | P0 |
| [流式比较](./streaming/streaming-comparison.md) | 跨框架流式模式比较 | P2 |
| [流式工具组装](./streaming/streaming-tool-assembly.md) | 流式增量工具调用组装 | P1 |
| [WebSocket 流式支持](./streaming/websocket-streaming-support.md) | WebSocket 流式设计模式 | P2 |
| [AgentScope 实时语音](./streaming/realtime-voice-agentscope.md) | 统一事件驱动模型、多模型适配、语音聊天室广播机制 | P0 |
| [Codex 流式处理](./streaming/codex-streaming.md) | WebSocket 实时对话、SSE 回退、增量请求优化 | P1 |

### [错误处理](./error-handling/)

结构化错误、重试策略和弹性模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [结构化错误与重试](./error-handling/structured-errors-retry.md) | 错误分类、重试策略、错误恢复 | P1 |

### [上下文管理](./context-management/)

会话历史、上下文转换和内存模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [上下文管理双模式](./context-management/context-management-dual-mode.md) | 审计 vs Token 优化：Tape anchor 切片、历史处理器 | P2 |
| [上下文转换比较](./context-management/context-transformation-comparison.md) | 上下文压缩和转换模式 | P2 |
| [会话历史管理](./context-management/session-history-management.md) | 会话持久化和历史管理 | P2 |
| [Codex 上下文管理](./context-management/codex-context-management.md) | Token 估算、上下文压缩、引用追踪 | P1 |

### [类型安全](./type-safety/)

类型安全的消息层次结构和序列化模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [类型化消息部件](./type-safety/typed-message-parts-pydantic-ai.md) | 类型安全消息部件：UserContent 联合、ModelMessage 层次结构 | P0 |

### [中间件](./middleware/)

回调和可扩展性系统。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [中间件/回调系统](./middleware/middleware-callback-system.md) | 可扩展性钩子：BaseCallbackHandler、RunnableConfig、astream_events | P2 |

### [并发](./concurrency/)

状态快照和并发模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [状态快照并发](./concurrency/state-snapshot-concurrency.md) | 双模式并发：EventStream、部分快照、UI 状态同步 | P2 |

### [架构](./architecture/)

框架架构分析和设计模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [Kimi CLI 架构](./architecture/kimi-cli-architecture.md) | 分层架构：Soul/Wire/UI 分离、D-Mail、Steer 模式 | P2 |
| [Republic Anchor 机制](./architecture/republic-anchor-mechanism.md) | Tape Anchor 上下文切片实现 | P2 |
| [OpenClaw Opik 可观测性插件架构](./architecture/openclaw-opik-observability-plugin.md) | 事件投影式 tracing：hook、状态聚合、延迟 finalize、附件旁路上传 | P1 |
| [Codex LLM 抽象层](./architecture/codex-llm-abstraction.md) | ModelClient/Session 设计、WebSocket 预热、流式回退 | P1 |

### [抽象层](./abstractions/)

LLM 抽象层比较和 SDK 模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [LLM 抽象比较](./abstractions/llm-abstraction-comparison.md) | 提供者抽象层设计模式 | P2 |
| [LLM 调用返回封装](./abstractions/llm-call-return-encapsulation.md) | LLM 调用的 SDK 使用模式 | P2 |
| [LLM 框架比较](./abstractions/llm-framework-comparison.md) | 综合框架比较（LitAI, Pydantic AI, Republic, Kimi CLI, LangChain） | P2 |

### [WebSocket](./websocket/)

WebSocket 协议比较。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [OpenAI WebSocket 比较](./websocket/openai-websocket-comparison.md) | OpenAI WebSocket 与框架实现比较 | P2 |

### [机器人技术](./robotics/)

机器人运动控制和 Embodied AI 模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [分层运动系统](./robotics/layered-motion-system.md) | 主要动作与次要偏移的融合架构、100Hz 控制循环、线程安全状态管理 | P0 |
| [机器人情绪系统设计](./robotics/emotion-system-design.md) | 情绪/舞蹈/呼吸状态切换、语音同步摆动、产品鲜活感设计考量 | P0 |

---

## 按优先级分类

| 优先级 | 文档 | 主题 |
|--------|------|------|
| P0 | [异步流式一等公民](./streaming/async-streaming-first-class.md) | 核心抽象 |
| P0 | [类型化消息部件](./type-safety/typed-message-parts-pydantic-ai.md) | 类型安全 |
| P0 | [分层运动系统](./robotics/layered-motion-system.md) | 机器人控制 |
| P0 | [机器人情绪系统设计](./robotics/emotion-system-design.md) | 机器人情绪 |
| P0 | [AgentScope 实时语音](./streaming/realtime-voice-agentscope.md) | 实时交互 |
| P1 | [结构化错误与重试](./error-handling/structured-errors-retry.md) | 生产健壮性 |
| P1 | [流式工具组装](./streaming/streaming-tool-assembly.md) | 流式处理 |
| P1 | [Codex LLM 抽象层](./architecture/codex-llm-abstraction.md) | 架构设计 |
| P1 | [OpenClaw Opik 可观测性插件架构](./architecture/openclaw-opik-observability-plugin.md) | 可观测性架构 |
| P1 | [Codex 流式处理](./streaming/codex-streaming.md) | 流式架构 |
| P1 | [Codex 上下文管理](./context-management/codex-context-management.md) | 上下文管理 |
| P2 | [上下文管理双模式](./context-management/context-management-dual-mode.md) | 状态管理 |
| P2 | [中间件/回调系统](./middleware/middleware-callback-system.md) | 可扩展性 |
| P2 | [状态快照并发](./concurrency/state-snapshot-concurrency.md) | 并发 |

---

## 添加笔记

1. 在相应主题子目录下创建文档
2. 遵循 [学习笔记模板](../../templates/learning-note-template.md)
3. 更新本 README 索引
4. 提交 PR

**[查看贡献指南 →](../../../CONTRIBUTING.md)**

---

*最后更新：2026-03-10*
