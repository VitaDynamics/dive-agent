# 文档索引

## 学习笔记

跨框架的模式和实践深度分析。

### 按主题分类

#### [流式处理](./learns/streaming/)
异步流式、WebSocket 模式和实时通信。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [异步流式一等公民](./learns/streaming/async-streaming-first-class.md) | 流式作为核心抽象：StreamedMessage 协议、Pull/Push/Hybrid 模式 | P0 |
| [流式比较](./learns/streaming/streaming-comparison.md) | 跨框架流式模式比较 | P2 |
| [流式工具组装](./learns/streaming/streaming-tool-assembly.md) | 流式增量工具调用组装 | P1 |
| [WebSocket 流式支持](./learns/streaming/websocket-streaming-support.md) | WebSocket 流式设计模式 | P2 |

#### [错误处理](./learns/error-handling/)
结构化错误、重试策略和弹性模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [结构化错误与重试](./learns/error-handling/structured-errors-retry.md) | 错误分类、重试策略、错误恢复 | P1 |

#### [上下文管理](./learns/context-management/)
会话历史、上下文转换和内存模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [上下文管理双模式](./learns/context-management/context-management-dual-mode.md) | 审计 vs Token 优化：Tape anchor 切片、历史处理器 | P2 |
| [上下文转换比较](./learns/context-management/context-transformation-comparison.md) | 上下文压缩和转换模式 | P2 |
| [会话历史管理](./learns/context-management/session-history-management.md) | 会话持久化和历史管理 | P2 |

#### [类型安全](./learns/type-safety/)
类型安全的消息层次结构和序列化模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [类型化消息部件](./learns/type-safety/typed-message-parts-pydantic-ai.md) | 类型安全消息部件：UserContent 联合、ModelMessage 层次结构 | P0 |

#### [中间件](./learns/middleware/)
回调和可扩展性系统。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [中间件/回调系统](./learns/middleware/middleware-callback-system.md) | 可扩展性钩子：BaseCallbackHandler、RunnableConfig、astream_events | P2 |

#### [并发](./learns/concurrency/)
状态快照和并发模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [状态快照并发](./learns/concurrency/state-snapshot-concurrency.md) | 双模式并发：EventStream、部分快照、UI 状态同步 | P2 |

#### [架构](./learns/architecture/)
框架架构分析和设计模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [Kimi CLI 架构](./learns/architecture/kimi-cli-architecture.md) | 分层架构：Soul/Wire/UI 分离、D-Mail、Steer 模式 | P2 |
| [Republic Anchor 机制](./learns/architecture/republic-anchor-mechanism.md) | Tape Anchor 上下文切片实现 | P2 |

#### [抽象层](./learns/abstractions/)
LLM 抽象层比较和 SDK 模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [LLM 抽象比较](./learns/abstractions/llm-abstraction-comparison.md) | 提供者抽象层设计模式 | P2 |
| [LLM 调用返回封装](./learns/abstractions/llm-call-return-encapsulation.md) | LLM 调用的 SDK 使用模式 | P2 |
| [LLM 框架比较](./learns/abstractions/llm-framework-comparison.md) | 综合框架比较（LitAI, Pydantic AI, Republic, Kimi CLI, LangChain） | P2 |

#### [WebSocket](./learns/websocket/)
WebSocket 协议比较。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [OpenAI WebSocket 比较](./learns/websocket/openai-websocket-comparison.md) | OpenAI WebSocket 与框架实现比较 | P2 |

---

### 按优先级分类

| 优先级 | 文档 | 主题 |
|--------|------|------|
| P0 | [异步流式一等公民](./learns/streaming/async-streaming-first-class.md) | 核心抽象 |
| P0 | [类型化消息部件](./learns/type-safety/typed-message-parts-pydantic-ai.md) | 类型安全 |
| P1 | [结构化错误与重试](./learns/error-handling/structured-errors-retry.md) | 生产健壮性 |
| P1 | [流式工具组装](./learns/streaming/streaming-tool-assembly.md) | 流式处理 |
| P2 | [上下文管理双模式](./learns/context-management/context-management-dual-mode.md) | 状态管理 |
| P2 | [中间件/回调系统](./learns/middleware/middleware-callback-system.md) | 可扩展性 |
| P2 | [状态快照并发](./learns/concurrency/state-snapshot-concurrency.md) | 并发 |

---

## 最佳实践

综合多个框架最佳实践的设计文档。

| 文档 | 描述 | 更新时间 |
|------|------|----------|
| [LLM 错误处理设计](./best-choices/llm-error-handling-design.md) | 结构化错误分类、重试策略、回退模式 | 2026-02-26 |
| [流式拉取防抖推送设计](./best-choices/streaming-pull-debounced-push-design.md) | 流式架构模式 | 2026-02-26 |

---

## 模板

| 模板 | 描述 |
|------|------|
| [学习笔记模板](./templates/learning-note-template.md) | 贡献新学习笔记的模板 |

---

## 贡献文档

贡献文档步骤：

1. 遵循 [学习笔记模板](./templates/learning-note-template.md)
2. 将文件放在 `docs/learns/<主题>/` 对应目录
3. 更新本 README 索引
4. 提交 PR

**[查看贡献指南 →](../CONTRIBUTING.md)**

---

*最后更新：2026-03-02*
