# 学习笔记

跨框架的模式和实践深度分析，按仓库类别组织。

---

## 按类别分类

### [Agent Harness](./harness/)（23 篇）

Agent 框架和编排工具的模式分析。

| 主题 | 描述 | 文档数 |
|------|------|--------|
| [流式处理](./harness/streaming/) | 异步流式、WebSocket 模式和实时通信 | 6 |
| [错误处理](./harness/error-handling/) | 结构化错误、重试策略和弹性模式 | 1 |
| [上下文管理](./harness/context-management/) | 会话历史、上下文转换和内存模式 | 4 |
| [类型安全](./harness/type-safety/) | 类型安全的消息层次结构和序列化模式 | 1 |
| [中间件](./harness/middleware/) | 回调和可扩展性系统 | 1 |
| [并发](./harness/concurrency/) | 状态快照和并发模式 | 1 |
| [架构](./harness/architecture/) | 框架架构分析和设计模式 | 3 |
| [抽象层](./harness/abstractions/) | LLM 抽象层比较和 SDK 模式 | 3 |
| [WebSocket](./harness/websocket/) | WebSocket 协议比较 | 1 |
| [机器人技术](./harness/robotics/) | 机器人运动控制和 Embodied AI 模式 | 2 |

**[查看详情 →](./harness/)**

---

### [Agent Evaluation](./evaluation/)（2 篇）

Agent 评估和测试框架的模式分析。

| 主题 | 描述 | 文档数 |
|------|------|--------|
| [Seed-driven Evaluation](./evaluation/seed-driven-evaluation/) | 基于 Seed 的自适应行为评估模式 | 1 |
| Production Tracing & Eval | 生产级 trace 与可定制评估方案 | 1 |

潜在主题：
- 基准测试框架设计
- Agent 行为评估指标
- 安全性评估方法
- 对抗性测试

**[查看详情 →](./evaluation/)**

---

### [Agent Training](./training/)（0 篇）

Agent 训练和微调相关的学习笔记。

*暂无文档 - 待添加*

潜在主题：
- RLHF 实现模式
- 指令微调策略
- 多轮对话训练
- 模型评估与迭代

**[查看详情 →](./training/)**

---

## 快速导航

### 按优先级（全类别）

| 优先级 | 文档 | 类别 | 主题 |
|--------|------|------|------|
| P0 | [异步流式一等公民](./harness/streaming/async-streaming-first-class.md) | Harness | 核心抽象 |
| P0 | [类型化消息部件](./harness/type-safety/typed-message-parts-pydantic-ai.md) | Harness | 类型安全 |
| P0 | [分层运动系统](./harness/robotics/layered-motion-system.md) | Harness | 机器人控制 |
| P0 | [机器人情绪系统设计](./harness/robotics/emotion-system-design.md) | Harness | 机器人情绪 |
| P0 | [AgentScope 实时语音](./harness/streaming/realtime-voice-agentscope.md) | Harness | 实时交互 |
| P1 | [Bloom: Seed-driven 行为评估](./evaluation/seed-driven-evaluation/bloom-behavioral-evaluation.md) | Evaluation | 安全评估 |
| P1 | [Opik Bloom 集成](./evaluation/opik-bloom-integration.md) | Evaluation | 评估集成 |
| P1 | [结构化错误与重试](./harness/error-handling/structured-errors-retry.md) | Harness | 生产健壮性 |
| P1 | [流式工具组装](./harness/streaming/streaming-tool-assembly.md) | Harness | 流式处理 |
| P1 | [Codex LLM 抽象层](./harness/architecture/codex-llm-abstraction.md) | Harness | 架构设计 |
| P1 | [Codex 流式处理](./harness/streaming/codex-streaming.md) | Harness | 流式架构 |
| P1 | [Codex 上下文管理](./harness/context-management/codex-context-management.md) | Harness | 上下文管理 |
| P2 | [上下文管理双模式](./harness/context-management/context-management-dual-mode.md) | Harness | 状态管理 |
| P2 | [上下文转换比较](./harness/context-management/context-transformation-comparison.md) | Harness | 上下文转换 |
| P2 | [会话历史管理](./harness/context-management/session-history-management.md) | Harness | 会话管理 |
| P2 | [中间件/回调系统](./harness/middleware/middleware-callback-system.md) | Harness | 可扩展性 |
| P2 | [状态快照并发](./harness/concurrency/state-snapshot-concurrency.md) | Harness | 并发 |
| P2 | [Kimi CLI 架构](./harness/architecture/kimi-cli-architecture.md) | Harness | 架构设计 |
| P2 | [Republic Anchor 机制](./harness/architecture/republic-anchor-mechanism.md) | Harness | 上下文切片 |
| P2 | [流式比较](./harness/streaming/streaming-comparison.md) | Harness | 流式对比 |
| P2 | [WebSocket 流式支持](./harness/streaming/websocket-streaming-support.md) | Harness | WebSocket |
| P2 | [OpenAI WebSocket 比较](./harness/websocket/openai-websocket-comparison.md) | Harness | WebSocket |
| P2 | [LLM 抽象比较](./harness/abstractions/llm-abstraction-comparison.md) | Harness | 抽象设计 |
| P2 | [LLM 调用返回封装](./harness/abstractions/llm-call-return-encapsulation.md) | Harness | SDK 模式 |
| P2 | [LLM 框架比较](./harness/abstractions/llm-framework-comparison.md) | Harness | 框架对比 |

---

## 添加笔记

### 目录结构

```
docs/learns/
├── harness/           # Agent 框架相关
│   └── <主题>/        # 已有主题或新建
├── evaluation/        # Agent 评估相关
│   └── <主题>/        # 待创建
└── training/          # Agent 训练相关
    └── <主题>/        # 待创建
```

### 步骤

1. **选择父类别**：
   - `harness` - 框架模式、架构设计
   - `evaluation` - 测试方法、评估指标
   - `training` - 训练策略、微调技术

2. **选择或创建主题**：在对应父类别下选择现有主题或创建新主题目录

3. **编写文档**：遵循 [学习笔记模板](../templates/learning-note-template.md)

4. **更新索引**：
   - 在父类别 README 中添加条目
   - 更新本文件的主索引

### 示例

添加关于 Bloom 评估框架的学习笔记：

```bash
# 1. 创建主题目录
mkdir -p docs/learns/evaluation/backdoor-detection

# 2. 编写文档
docs/learns/evaluation/backdoor-detection/bloom-analysis.md

# 3. 更新索引
docs/learns/evaluation/README.md  # 添加主题部分
docs/learns/README.md              # 更新统计
```

---

## 标签体系

学习笔记使用以下标签分类：

### 父类别标签
- `harness` - 框架相关
- `evaluation` - 评估相关
- `training` - 训练相关

### 主题标签
- `streaming`, `error-handling`, `type-safety`
- `middleware`, `architecture`, `concurrency`
- `benchmarks`, `testing`, `safety`
- `rl`, `fine-tuning`, `rlhf`

### 框架标签
- `pydantic-ai`, `langchain`, `republic`
- `kimi-cli`, `agentscope`, `agno`
- `bloom` 等

---

**[查看贡献指南 →](../../CONTRIBUTING.md)**

---

*最后更新：2026-03-04*
