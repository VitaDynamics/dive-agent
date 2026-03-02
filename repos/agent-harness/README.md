# Agent-harness

Agent frameworks and orchestration tools that provide core abstractions for building AI agents.

## Definition

Agent-harness frameworks provide:
- **State Management**: Conversation history, context windowing, checkpoint/revert
- **Tool Calling**: Function execution, parallel calls, streaming assembly
- **Streaming**: First-class async streaming support
- **Error Handling**: Structured errors, retry strategies, fallbacks
- **Extensibility**: Middleware, callbacks, hooks

## Indexed Repositories

### pydantic-ai

- **URL**: https://github.com/pydantic/pydantic-ai
- **Language**: Python
- **Key Features**:
  - Provider-agnostic (OpenAI, Anthropic, Gemini, etc.)
  - Full type safety with Pydantic models
  - Built-in observability with Logfire
  - MCP and A2A protocol support
- **Learning Notes**:
  - [Typed Message Parts](../../docs/learns/type-safety/typed-message-parts-pydantic-ai.md)
  - [Streaming Tool Assembly](../../docs/learns/streaming/streaming-tool-assembly.md)

### langchain

- **URL**: https://github.com/langchain-ai/langchain
- **Language**: Python
- **Key Features**:
  - Modular architecture (core, langchain, partners)
  - Rich ecosystem of integrations
  - LangGraph for stateful workflows
  - Production-ready with LangSmith observability
- **Learning Notes**:
  - [Middleware/Callback System](../../docs/learns/middleware/middleware-callback-system.md)
  - [Structured Errors & Retry](../../docs/learns/error-handling/structured-errors-retry.md)

### republic

- **URL**: https://github.com/fixie/republic
- **Language**: Python
- **Key Features**:
  - Tape-first design with complete audit trail
  - Anchor mechanism for context slicing
  - Zero magic, explicit workflows
- **Learning Notes**:
  - [Republic Anchor Mechanism](../../docs/learns/architecture/republic-anchor-mechanism.md)
  - [State Snapshot Concurrency](../../docs/learns/concurrency/state-snapshot-concurrency.md)

### litai

- **URL**: https://github.com/Lightning-AI/litai
- **Language**: Python
- **Key Features**:
  - Lightweight LLM router
  - Unified billing and rate limiting
  - Automatic retries and fallbacks
- **Learning Notes**:
  - [LLM Framework Comparison](../../docs/learns/abstractions/llm-framework-comparison.md)

### kimi-cli

- **URL**: https://github.com/MoonshotAI/kimi-cli
- **Language**: Python
- **Key Features**:
  - Terminal-based AI agent
  - Kosong streaming library
  - Shell mode and VS Code extension
  - MCP and ACP support
- **Learning Notes**:
  - [Kimi CLI Architecture](../../docs/learns/architecture/kimi-cli-architecture.md)
  - [Async Streaming First Class](../../docs/learns/streaming/async-streaming-first-class.md)

### pi-mono

- **URL**: https://github.com/pi-company/pi-mono
- **Language**: TypeScript
- **Key Features**:
  - Multi-package monorepo architecture
  - LLM deployment management
  - Coding agent with TUI and Web UI
- **Learning Notes**:
  - [Context Management Dual Mode](../../docs/learns/context-management/context-management-dual-mode.md)

---

## Comparison Matrix

| Feature | pydantic-ai | langchain | republic | kimi-cli |
|---------|-------------|-----------|----------|----------|
| Type Safety | ✅ Full | Partial | Partial | Partial |
| Streaming | ✅ First-class | ✅ Yes | ✅ Yes | ✅ First-class |
| Tool Calling | ✅ Parallel | ✅ Parallel | ✅ Sequential | ✅ Parallel |
| Error Handling | ✅ Structured | ✅ Callbacks | Basic | ✅ Structured |
| State Management | Graph-based | LangGraph | Tape-based | Tape-based |
| Observability | Logfire | LangSmith | Basic | Built-in |

---

*Last updated: 2026-03-02*
