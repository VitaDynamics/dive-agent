# Agent-harness

Agent 框架和编排工具，提供构建 AI Agent 的核心抽象。

## 定义

Agent-harness 框架提供：
- **状态管理**：对话历史、上下文窗口、检查点/回滚
- **工具调用**：函数执行、并行调用、流式组装
- **流式处理**：一等异步流式支持
- **错误处理**：结构化错误、重试策略、回退机制
- **可扩展性**：中间件、回调、钩子

## 已索引仓库

### agentscope

- **URL**: https://github.com/agentscope-ai/agentscope
- **语言**: Python
- **关键特性**:
  - 多智能体协作（MsgHub, ServiceMap）
  - 易用性设计（高层抽象，HIL 支持）
  - 分布式部署支持（K8s, Serverless）
  - 完善的可观测性（OpenTelemetry）
- **学习笔记**:
  - *暂无*

### agno

- **URL**: https://github.com/agno-agi/agno
- **语言**: Python
- **关键特性**:
  - 持久化内存（会话管理）
  - 知识库 (RAG) 支持
  - 多智能体团队和复杂工作流
  - AgentOS 控制面板用于监控和调试
- **学习笔记**:
  - *暂无*

### pydantic-ai

- **URL**: https://github.com/pydantic/pydantic-ai
- **语言**: Python
- **关键特性**:
  - 提供者无关（OpenAI, Anthropic, Gemini 等）
  - 基于 Pydantic 模型的完全类型安全
  - 内置 Logfire 可观测性
  - 支持 MCP 和 A2A 协议
- **学习笔记**:
  - [类型安全的消息部件](../../docs/learns/type-safety/typed-message-parts-pydantic-ai.md)
  - [流式工具组装](../../docs/learns/streaming/streaming-tool-assembly.md)

### langchain

- **URL**: https://github.com/langchain-ai/langchain
- **语言**: Python
- **关键特性**:
  - 模块化架构（core, langchain, partners）
  - 丰富的集成生态系统
  - LangGraph 用于有状态工作流
  - 基于 LangSmith 的生产级可观测性
- **学习笔记**:
  - [中间件/回调系统](../../docs/learns/middleware/middleware-callback-system.md)
  - [结构化错误与重试](../../docs/learns/error-handling/structured-errors-retry.md)

### republic

- **URL**: https://github.com/fixie/republic
- **语言**: Python
- **关键特性**:
  - Tape-first 设计，完整审计追踪
  - Anchor 机制用于上下文切片
  - 零魔法，显式工作流
- **学习笔记**:
  - [Republic Anchor 机制](../../docs/learns/architecture/republic-anchor-mechanism.md)
  - [状态快照并发](../../docs/learns/concurrency/state-snapshot-concurrency.md)

### litai

- **URL**: https://github.com/Lightning-AI/litai
- **语言**: Python
- **关键特性**:
  - 轻量级 LLM 路由器
  - 统一计费和速率限制
  - 自动重试和回退
- **学习笔记**:
  - [LLM 框架比较](../../docs/learns/abstractions/llm-framework-comparison.md)

### kimi-cli

- **URL**: https://github.com/MoonshotAI/kimi-cli
- **语言**: Python
- **关键特性**:
  - 终端 AI Agent
  - Kosong 流式库
  - Shell 模式和 VS Code 扩展
  - 支持 MCP 和 ACP
- **学习笔记**:
  - [Kimi CLI 架构](../../docs/learns/architecture/kimi-cli-architecture.md)
  - [异步流式一等公民](../../docs/learns/streaming/async-streaming-first-class.md)

### pi-mono

- **URL**: https://github.com/pi-company/pi-mono
- **语言**: TypeScript
- **关键特性**:
  - 多包 monorepo 架构
  - LLM 部署管理
  - 编码 Agent，包含 TUI 和 Web UI
- **学习笔记**:
  - [上下文管理双模式](../../docs/learns/context-management/context-management-dual-mode.md)

### livekit-agents

- **URL**: https://github.com/livekit/agents
- **语言**: Python
- **关键特性**:
  - 实时语音/视频 AI Agent 管道框架
  - 基于 WebRTC 的低延迟实时通信
  - 支持 STT/TTS/LLM 多模态流水线
  - 插件系统支持 OpenAI、Deepgram、ElevenLabs 等
  - 内置 VAD（语音活动检测）
- **学习笔记**:
  - *暂无*

---

## 比较矩阵

| 特性 | agentscope | agno | pydantic-ai | langchain | republic | kimi-cli | livekit-agents |
|------|------------|------|-------------|-----------|----------|----------|----------------|
| 多智能体 | ✅ MsgHub | ✅ 团队 | 基础 | LangGraph | 基础 | 基础 | 基础 |
| 流式处理 | ✅ 支持 | ✅ 支持 | ✅ 一等公民 | ✅ 支持 | ✅ 支持 | ✅ 一等公民 | ✅ 实时 WebRTC |
| 工具调用 | ✅ ServiceMap | ✅ 并行 | ✅ 并行 | ✅ 并行 | ✅ 顺序 | ✅ 并行 | ✅ 插件系统 |
| 部署 | ✅ 分布式 | ✅ 生产 API | 库 | 库 | 库 | 库 | ✅ 云原生 |
| 状态管理 | 集中式/分布式 | 会话管理 | 基于图 | LangGraph | 基于 Tape | 基于 Tape | 管道状态 |
| 可观测性 | OTel/UI | AgentOS | Logfire | LangSmith | 基础 | 内置 | 基础 |

---

*最后更新：2026-03-20*
