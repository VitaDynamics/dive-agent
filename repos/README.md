# 仓库索引

按类别组织的 Agent 相关仓库精选集合。

## 分类

### [Agent](./agent/)（3 个仓库）

独立的 AI Agent 应用和实现，可直接使用。

| 仓库 | 描述 | 语言 | 状态 |
|------|------|------|------|
| [om1](https://github.com/OpenMind/OM1) | 模块化机器人 AI 运行时和框架，用于人形机器人 | Python | ✅ |
| [reachy-mini-conversation-app](https://github.com/pollen-robotics/reachy_mini_conversation_app) | Reachy Mini 机器人对话应用，结合 OpenAI 实时 API、视觉管道和动作库 | Python | ✅ |
| [codex](https://github.com/openai/codex) | OpenAI 的轻量级编码 Agent，在终端中运行 | TypeScript | - |

**[查看详情 →](./agent/README.md)**

---

### [Agent-harness](./agent-harness/)（8 个仓库）

Agent 框架和编排工具，提供构建 AI Agent 的核心抽象。

| 仓库 | 描述 | 语言 |
|------|------|------|
| [agentscope](https://github.com/agentscope-ai/agentscope) | 用于构建应用程序的多智能体平台 | Python |
| [agno](https://github.com/agno-agi/agno) | Framework for building AI Agents with memory, knowledge, and tools | Python |
| [pydantic-ai](https://github.com/pydantic/pydantic-ai) | 提供者无关的 GenAI Agent 框架，完全类型安全 | Python |
| [langchain](https://github.com/langchain-ai/langchain) | 构建上下文感知推理应用 | Python |
| [republic](https://github.com/fixie/republic) | 基于 Tape 的 Agent 框架，完整审计追踪 | Python |
| [litai](https://github.com/Lightning-AI/litai) | 轻量级 LLM 路由器，统一计费 | Python |
| [kimi-cli](https://github.com/MoonshotAI/kimi-cli) | 终端 Agent，包含 kosong 流式库 | Python |
| [pi-mono](https://github.com/pi-company/pi-mono) | 多提供者 LLM 抽象 monorepo | TypeScript |

**[查看详情 →](./agent-harness/README.md)**

---

### [Agent Evaluation](./agent-evaluation/)（4 个仓库）

Agent 性能测试和评估框架。

| 仓库 | 描述 | 语言 | 状态 |
|------|------|------|------|
| [opik](https://github.com/comet-ml/opik) | 开源 LLM 评估与观测平台，支持追踪、自动评估及生产监控 | Python | - |
| [bloom](https://github.com/safety-research/bloom) | Backdooring LLMs for multi-agent environments | Python | - |
| [ACEBench](https://github.com/chenchen0103/ACEBench) | A comprehensive benchmark for assessing tool usage in LLMs | Python | - |
| [langfuse](https://github.com/langfuse/langfuse) | 生产级 trace + 可定制 eval 长期方案 | TypeScript | - |

**[查看详情 →](./agent-evaluation/README.md)**

---

### [Agent Training](./agent-training/)（0 个仓库）

Agent 模型训练和微调资源。

| 仓库 | 描述 | 语言 | 状态 |
|------|------|------|------|
| *暂无* | - | - | - |

**[查看详情 →](./agent-training/README.md)**

---

## 添加仓库

要将仓库添加到此索引：

1. 使用 [添加仓库模板](../../issues/new?template=add-repository.yml) 创建 Issue
2. 提供仓库 URL、类别和简要描述
3. 维护者将审核并更新索引

## 类别定义

| 类别 | 定义 | 示例 |
|------|------|------|
| **Agent** | 可直接使用的独立 AI Agent 应用 | CLI 助手、聊天机器人、自动化 Agent |
| **Agent-harness** | 提供 Agent 核心抽象的框架（状态管理、工具调用、流式处理） | pydantic-ai, langchain, republic |
| **Agent Evaluation** | Agent 行为基准测试、测试和评估工具 | agent-eval, agent-bench |
| **Agent Training** | Agent 模型训练、微调和优化资源 | agent-trainer, rl-agent |

---

*最后更新：2026-03-04*
