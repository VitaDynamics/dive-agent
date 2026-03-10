# 文档索引

## 学习笔记

跨框架的模式和实践深度分析。

### 按主题分类

#### [流式处理](./learns/harness/streaming/)
异步流式、WebSocket 模式和实时通信。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [异步流式一等公民](./learns/harness/streaming/async-streaming-first-class.md) | 流式作为核心抽象：StreamedMessage 协议、Pull/Push/Hybrid 模式 | P0 |
| [流式比较](./learns/harness/streaming/streaming-comparison.md) | 跨框架流式模式比较 | P2 |
| [流式工具组装](./learns/harness/streaming/streaming-tool-assembly.md) | 流式增量工具调用组装 | P1 |
| [WebSocket 流式支持](./learns/harness/streaming/websocket-streaming-support.md) | WebSocket 流式设计模式 | P2 |
| [AgentScope 实时语音](./learns/streaming/realtime-voice-agentscope.md) | 统一事件驱动模型、多模型适配、语音聊天室广播机制 | P0 |
| [实时 vs. Kosong 对比](./learns/streaming/realtime-vs-kosong.md) | 感官实时 vs. 逻辑流式的架构哲学对比 | P0 |

#### [错误处理](./learns/harness/error-handling/)
结构化错误、重试策略和弹性模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [结构化错误与重试](./learns/harness/error-handling/structured-errors-retry.md) | 错误分类、重试策略、错误恢复 | P1 |

#### [上下文管理](./learns/harness/context-management/)
会话历史、上下文转换和内存模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [上下文管理双模式](./learns/harness/context-management/context-management-dual-mode.md) | 审计 vs Token 优化：Tape anchor 切片、历史处理器 | P2 |
| [上下文转换比较](./learns/harness/context-management/context-transformation-comparison.md) | 上下文压缩和转换模式 | P2 |
| [会话历史管理](./learns/harness/context-management/session-history-management.md) | 会话持久化和历史管理 | P2 |

#### [类型安全](./learns/harness/type-safety/)
类型安全的消息层次结构和序列化模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [类型化消息部件](./learns/harness/type-safety/typed-message-parts-pydantic-ai.md) | 类型安全消息部件：UserContent 联合、ModelMessage 层次结构 | P0 |

#### [中间件](./learns/harness/middleware/)
回调和可扩展性系统。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [中间件/回调系统](./learns/harness/middleware/middleware-callback-system.md) | 可扩展性钩子：BaseCallbackHandler、RunnableConfig、astream_events | P2 |

#### [并发](./learns/harness/concurrency/)
状态快照和并发模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [状态快照并发](./learns/harness/concurrency/state-snapshot-concurrency.md) | 双模式并发：EventStream、部分快照、UI 状态同步 | P2 |

#### [架构](./learns/harness/architecture/)
框架架构分析和设计模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [Kimi CLI 架构](./learns/harness/architecture/kimi-cli-architecture.md) | 分层架构：Soul/Wire/UI 分离、D-Mail、Steer 模式 | P2 |
| [Republic Anchor 机制](./learns/harness/architecture/republic-anchor-mechanism.md) | Tape Anchor 上下文切片实现 | P2 |
| [OpenClaw Opik 可观测性插件架构](./learns/harness/architecture/openclaw-opik-observability-plugin.md) | 事件投影式 tracing：hook 到 trace/span 的状态聚合与收尾链路 | P1 |
| [NanoClaw 架构](./learns/harness/architecture/nanoclaw-architecture.md) | NanoClaw 架构设计分析 | P1 |
| [Codex LLM 抽象层](./learns/harness/architecture/codex-llm-abstraction.md) | ModelClient/Session 设计、WebSocket 预热、流式回退 | P1 |

#### [抽象层](./learns/harness/abstractions/)
LLM 抽象层比较和 SDK 模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [LLM 抽象比较](./learns/harness/abstractions/llm-abstraction-comparison.md) | 提供者抽象层设计模式 | P2 |
| [LLM 调用返回封装](./learns/harness/abstractions/llm-call-return-encapsulation.md) | LLM 调用的 SDK 使用模式 | P2 |
| [LLM 框架比较](./learns/harness/abstractions/llm-framework-comparison.md) | 综合框架比较（LitAI, Pydantic AI, Republic, Kimi CLI, LangChain） | P2 |

#### [WebSocket](./learns/harness/websocket/)
WebSocket 协议比较。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [OpenAI WebSocket 比较](./learns/harness/websocket/openai-websocket-comparison.md) | OpenAI WebSocket 与框架实现比较 | P2 |

#### [机器人技术](./learns/harness/robotics/)
机器人运动控制和 Embodied AI 模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [分层运动系统](./learns/harness/robotics/layered-motion-system.md) | 主要动作与次要偏移的融合架构、100Hz 控制循环、线程安全状态管理 | P0 |
| [机器人情绪系统设计](./learns/harness/robotics/emotion-system-design.md) | 情绪/舞蹈/呼吸状态切换、语音同步摆动、产品鲜活感设计考量 | P0 |

#### [评估](./learns/evaluation/)
Agent 性能测试、安全评估和观测模式。

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [Opik 与 Bloom 融合](./learns/evaluation/opik-bloom-integration.md) | 攻击模拟-深度观测-防御评估的有机闭环 | P1 |
| [Bloom 行为评估](./learns/evaluation/seed-driven-evaluation/bloom-behavioral-evaluation.md) | Seed-driven 自适应行为评估、后门攻击检测 | P2 |

---

### 按优先级分类

| 优先级 | 文档 | 主题 |
|--------|------|------|
| P0 | [异步流式一等公民](./learns/harness/streaming/async-streaming-first-class.md) | 核心抽象 |
| P0 | [类型化消息部件](./learns/harness/type-safety/typed-message-parts-pydantic-ai.md) | 类型安全 |
| P0 | [分层运动系统](./learns/harness/robotics/layered-motion-system.md) | 机器人控制 |
| P0 | [机器人情绪系统设计](./learns/harness/robotics/emotion-system-design.md) | 机器人情绪 |
| P0 | [AgentScope 实时语音](./learns/streaming/realtime-voice-agentscope.md) | 实时交互 |
| P0 | [实时 vs. Kosong 对比](./learns/streaming/realtime-vs-kosong.md) | 架构对比 |
| P1 | [Opik 与 Bloom 融合](./learns/evaluation/opik-bloom-integration.md) | 安全评估 |
| P1 | [结构化错误与重试](./learns/harness/error-handling/structured-errors-retry.md) | 生产健壮性 |
| P1 | [流式工具组装](./learns/harness/streaming/streaming-tool-assembly.md) | 流式处理 |
| P1 | [OpenClaw Opik 可观测性插件架构](./learns/harness/architecture/openclaw-opik-observability-plugin.md) | 可观测性架构 |
| P2 | [Bloom 行为评估](./learns/evaluation/seed-driven-evaluation/bloom-behavioral-evaluation.md) | 行为评估 |
| P2 | [上下文管理双模式](./learns/harness/context-management/context-management-dual-mode.md) | 状态管理 |
| P2 | [中间件/回调系统](./learns/harness/middleware/middleware-callback-system.md) | 可扩展性 |
| P2 | [状态快照并发](./learns/harness/concurrency/state-snapshot-concurrency.md) | 并发 |

---

## 最佳实践

综合多个框架最佳实践的设计文档。

| 文档 | 描述 | 更新时间 |
|------|------|----------|
| [LLM 错误处理设计](./best-choices/llm-error-handling-design.md) | 结构化错误分类、重试策略、回退模式 | 2026-02-26 |
| [流式拉取防抖推送设计](./best-choices/streaming-pull-debounced-push-design.md) | 流式架构模式 | 2026-02-26 |
| [机器人情绪与动作系统设计](./best-choices/emotion-motion-system-design.md) | 永不静止原则、双层融合架构、音频驱动运动 | 2026-03-02 |

---

## 模板

| 模板 | 描述 |
|------|------|
| [学习笔记模板](./templates/learning-note-template.md) | 贡献新学习笔记的模板 |

---

## 贡献文档

贡献文档步骤：

1. 遵循 [学习笔记模板](./templates/learning-note-template.md)
2. 将文件放在 `docs/learns/harness/<主题>/` 或对应类别的目录
3. 更新本 README 索引
4. 提交 PR

**[查看贡献指南 →](../CONTRIBUTING.md)**

---

*最后更新：2026-03-10*
