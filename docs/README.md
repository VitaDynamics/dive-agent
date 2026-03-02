# Documentation Index

## Learning Notes

In-depth analysis of patterns and practices across Agent frameworks.

### By Topic

#### [Streaming](./learns/streaming/)
Async streaming, WebSocket patterns, and real-time communication.

| Document | Description | Priority |
|----------|-------------|----------|
| [Async Streaming First Class](./learns/streaming/async-streaming-first-class.md) | Streaming as core abstraction: StreamedMessage Protocol, Pull/Push/Hybrid patterns | P0 |
| [Streaming Comparison](./learns/streaming/streaming-comparison.md) | Cross-framework streaming patterns comparison | P2 |
| [Streaming Tool Assembly](./learns/streaming/streaming-tool-assembly.md) | Incremental tool call assembly with streaming | P1 |
| [WebSocket Streaming Support](./learns/streaming/websocket-streaming-support.md) | WebSocket streaming design patterns | P2 |

#### [Error Handling](./learns/error-handling/)
Structured errors, retry strategies, and resilience patterns.

| Document | Description | Priority |
|----------|-------------|----------|
| [Structured Errors & Retry](./learns/error-handling/structured-errors-retry.md) | Error classification, retry strategies, error recovery | P1 |

#### [Context Management](./learns/context-management/)
Session history, context transformation, and memory patterns.

| Document | Description | Priority |
|----------|-------------|----------|
| [Context Management Dual Mode](./learns/context-management/context-management-dual-mode.md) | Audit vs Token optimization: Tape anchor slicing, history processors | P2 |
| [Context Transformation Comparison](./learns/context-management/context-transformation-comparison.md) | Context compaction and transformation patterns | P2 |
| [Session History Management](./learns/context-management/session-history-management.md) | Session persistence and history management | P2 |

#### [Type Safety](./learns/type-safety/)
Type-safe message hierarchies and serialization patterns.

| Document | Description | Priority |
|----------|-------------|----------|
| [Typed Message Parts](./learns/type-safety/typed-message-parts-pydantic-ai.md) | Type-safe message parts: UserContent union, ModelMessage hierarchy | P0 |

#### [Middleware](./learns/middleware/)
Callback and extensibility systems.

| Document | Description | Priority |
|----------|-------------|----------|
| [Middleware/Callback System](./learns/middleware/middleware-callback-system.md) | Extensibility hooks: BaseCallbackHandler, RunnableConfig, astream_events | P2 |

#### [Concurrency](./learns/concurrency/)
State snapshot and concurrency patterns.

| Document | Description | Priority |
|----------|-------------|----------|
| [State Snapshot Concurrency](./learns/concurrency/state-snapshot-concurrency.md) | Dual-mode concurrency: EventStream, partial snapshots, UI state sync | P2 |

#### [Architecture](./learns/architecture/)
Framework architecture analysis and design patterns.

| Document | Description | Priority |
|----------|-------------|----------|
| [Kimi CLI Architecture](./learns/architecture/kimi-cli-architecture.md) | Layered architecture: Soul/Wire/UI separation, D-Mail, Steer mode | P2 |
| [Republic Anchor Mechanism](./learns/architecture/republic-anchor-mechanism.md) | Tape Anchor context slicing implementation | P2 |

#### [Abstractions](./learns/abstractions/)
LLM abstraction layer comparisons and SDK patterns.

| Document | Description | Priority |
|----------|-------------|----------|
| [LLM Abstraction Comparison](./learns/abstractions/llm-abstraction-comparison.md) | Provider abstraction layer design patterns | P2 |
| [LLM Call Return Encapsulation](./learns/abstractions/llm-call-return-encapsulation.md) | SDK usage patterns for LLM calls | P2 |
| [LLM Framework Comparison](./learns/abstractions/llm-framework-comparison.md) | Comprehensive framework comparison (LitAI, Pydantic AI, Republic, Kimi CLI, LangChain) | P2 |

#### [WebSocket](./learns/websocket/)
WebSocket protocol comparisons.

| Document | Description | Priority |
|----------|-------------|----------|
| [OpenAI WebSocket Comparison](./learns/websocket/openai-websocket-comparison.md) | OpenAI WebSocket vs framework implementations | P2 |

---

### By Priority

| Priority | Document | Topic |
|----------|----------|-------|
| P0 | [Async Streaming First Class](./learns/streaming/async-streaming-first-class.md) | Core Abstractions |
| P0 | [Typed Message Parts](./learns/type-safety/typed-message-parts-pydantic-ai.md) | Type Safety |
| P1 | [Structured Errors & Retry](./learns/error-handling/structured-errors-retry.md) | Production Robustness |
| P1 | [Streaming Tool Assembly](./learns/streaming/streaming-tool-assembly.md) | Streaming |
| P2 | [Context Management Dual Mode](./learns/context-management/context-management-dual-mode.md) | State Management |
| P2 | [Middleware/Callback System](./learns/middleware/middleware-callback-system.md) | Extensibility |
| P2 | [State Snapshot Concurrency](./learns/concurrency/state-snapshot-concurrency.md) | Concurrency |

---

## Best Choices

Design documents synthesizing best practices from multiple frameworks.

| Document | Description | Updated |
|----------|-------------|---------|
| [LLM Error Handling Design](./best-choices/llm-error-handling-design.md) | Structured error classification, retry strategies, fallback patterns | 2026-02-26 |
| [Streaming Pull Debounced Push Design](./best-choices/streaming-pull-debounced-push-design.md) | Streaming architecture patterns | 2026-02-26 |

---

## Templates

| Template | Description |
|----------|-------------|
| [Learning Note Template](./templates/learning-note-template.md) | Template for contributing new learning notes |

---

## Contributing

To contribute documentation:

1. Follow the [Learning Note Template](./templates/learning-note-template.md)
2. Place the file in the appropriate topic subdirectory under `docs/learns/<topic>/`
3. Update this README index
4. Submit a PR

**[View Contributing Guide →](../CONTRIBUTING.md)**

---

*Last updated: 2026-03-02*
