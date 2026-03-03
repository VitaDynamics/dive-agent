---
tags: evaluation, observability, trace, langfuse, flexibility, production
---

# 生产级 Trace 与可定制 Eval 方案 - Langfuse

> **范围**：本文档深入分析 Langfuse 作为 LLM 工程平台的核心能力，重点探讨其相比其他评估工具（如 Opik）的灵活性优势。
>
> **综合自**：Langfuse
>
> **优先级**：P1

---

## 概述

Langfuse 是一个开源的 LLM 工程平台，专注于为 AI 应用提供**可观测性**、**提示管理**、**评估**和**数据集管理**能力。与其他评估工具相比，Langfuse 的核心优势在于：

1. **生产级架构**：基于 ClickHouse + Redis + PostgreSQL 的高性能分布式架构
2. **极致灵活的 Trace 系统**：支持 10+ 种观测类型，可任意组合和嵌套
3. **可定制的 Evaluation Pipeline**：通过模板变量映射系统实现高度可配置的评估流程
4. **无侵入式集成**：支持 LangChain、LlamaIndex 等主流框架的一键集成

---

## 核心架构

### 1. 分层架构设计

```
┌─────────────────────────────────────┐
│      Web UI (Next.js)               │  ← 提供 Trace 可视化、Prompt 管理、Playground
├─────────────────────────────────────┤
│      Worker (Background Jobs)       │  ← 处理异步评估任务、Trace 聚合
├─────────────────────────────────────┤
│      API Layer (tRPC + REST)        │  ← 对外 SDK 接口
├─────────────────────────────────────┤
│  Storage Layer                      │
│  ├─ PostgreSQL (元数据)             │  ← 用户、项目、配置
│  ├─ ClickHouse (时序数据)           │  ← Traces、Observations、Metrics
│  ├─ Redis (缓存 + 队列)             │  ← Eval Job Queue、配置缓存
│  └─ S3/MinIO (大对象存储)           │  ← 大输入/输出、媒体文件
└─────────────────────────────────────┘
```

**设计理由**：
- **ClickHouse** 用于高速写入和聚合查询（百万级 traces）
- **PostgreSQL** 保证元数据的事务一致性
- **Redis** 提供 10 分钟 TTL 的配置缓存，减少数据库查询

**权衡**：
- 优点：可水平扩展、适合生产环境
- 缺点：部署复杂度较高（需要 4 个基础设施组件）

---

## 灵活的 Trace 系统

### 2. 多类型 Observation 抽象

Langfuse 定义了 10 种观测类型，每种都有特定语义：

```typescript
export const ObservationType = {
  SPAN: "SPAN",              // 通用时间跨度
  EVENT: "EVENT",            // 离散事件
  GENERATION: "GENERATION",  // LLM 生成调用
  AGENT: "AGENT",            // Agent 决策单元
  TOOL: "TOOL",              // 工具调用
  CHAIN: "CHAIN",            // 链式调用
  RETRIEVER: "RETRIEVER",    // 检索操作
  EVALUATOR: "EVALUATOR",    // 评估器执行
  EMBEDDING: "EMBEDDING",    // 嵌入生成
  GUARDRAIL: "GUARDRAIL",    // 安全防护检查
} as const;
```

**关键设计**：
- 每种类型共享统一的 `ObservationSchema`（metadata, input, output, timestamps）
- 但可携带类型特定的字段（如 GENERATION 有 `model`、`usage`、`cost`）
- 所有 Observation 通过 `parentObservationId` 构建树形结构

```typescript
export const ObservationSchema = z.object({
  id: z.string(),
  traceId: z.string().nullable(),
  type: ObservationTypeDomain,
  startTime: z.date(),
  endTime: z.date().nullable(),
  name: z.string().nullable(),
  metadata: MetadataDomain,
  parentObservationId: z.string().nullable(),
  // ... 类型特定字段
  model: z.string().nullable(),           // 仅 GENERATION
  toolDefinitions: z.record(...).nullable(),  // 仅 TOOL
  costDetails: z.record(...),             // 仅 GENERATION
});
```

**与 Opik 对比**：
- Opik 主要关注 `Trace`、`Span`、`LLMCall` 三层抽象
- Langfuse 提供了更细粒度的语义标签（AGENT、EVALUATOR、GUARDRAIL），便于按类型过滤和分析

---

### 3. 灵活的 Trace 组合模式

Langfuse 的 Trace 可以表达复杂的工作流：

```python
# 示例：多 Agent 协作的 Trace 结构
Trace: "multi-agent-task"
├─ AGENT: "coordinator"
│  ├─ GENERATION: "plan-creation"
│  ├─ TOOL: "search-database"
│  └─ CHAIN: "subtask-dispatch"
│     ├─ AGENT: "specialist-1"
│     │  ├─ RETRIEVER: "vector-search"
│     │  └─ GENERATION: "answer-gen"
│     └─ AGENT: "specialist-2"
│        └─ GENERATION: "critique"
└─ EVALUATOR: "quality-check"
   └─ GENERATION: "llm-as-judge"
```

**设计优势**：
- 可以在同一 Trace 内混合不同抽象层级
- EVALUATOR 类型天然支持"评估即观测"的模式
- 通过 `tags` 和 `metadata` 可以附加任意上下文

---

## 可定制的 Evaluation 系统

### 4. 模板变量映射机制

Langfuse 的 Eval 配置核心是 **Variable Mapping**，允许从 Trace/Observation 的任意字段提取值作为评估模板的输入：

```typescript
export const variableMapping = z.object({
  templateVariable: z.string(),      // 模板中的变量名，如 {{input}}
  objectName: z.string().nullish(),  // 要提取的 observation 名称
  langfuseObject: z.enum([           // 对象类型
    "trace", "generation", "agent", "tool", ...
  ]),
  selectedColumnId: z.string(),      // 字段名：input/output/metadata
  jsonSelector: z.string().nullish(), // JSONPath 选择器，如 $.messages[0].content
});
```

**实际应用示例**：

假设要评估一个 Agent 的输出质量，配置如下：

```json
{
  "templateVariables": [
    {
      "templateVariable": "user_query",
      "langfuseObject": "trace",
      "selectedColumnId": "input"
    },
    {
      "templateVariable": "agent_response",
      "langfuseObject": "agent",
      "objectName": "main-agent",
      "selectedColumnId": "output"
    },
    {
      "templateVariable": "retrieved_docs",
      "langfuseObject": "retriever",
      "objectName": "vector-search",
      "selectedColumnId": "output",
      "jsonSelector": "$.documents[*].text"
    }
  ]
}
```

评估模板（LLM-as-a-Judge）：
```
Given the user query: {{user_query}}
And retrieved context: {{retrieved_docs}}
Evaluate if the agent response: {{agent_response}}
is accurate and helpful.
```

**灵活性体现**：
1. 可以从 Trace 的任意层级提取数据
2. 支持 JSONPath 进行复杂数据提取
3. 同一 Trace 可以配置多个不同维度的评估器

---

### 5. 多目标 Eval 支持

Langfuse 支持 4 种评估目标：

```typescript
export const EvalTargetObject = {
  TRACE: "trace",        // 评估整个 Trace（端到端质量）
  DATASET: "dataset",    // 评估 Dataset Item（回归测试）
  EVENT: "event",        // 评估单个事件（实时反馈）
  EXPERIMENT: "experiment", // 评估实验运行（A/B 测试）
} as const;
```

**使用场景**：
- **TRACE**：生产环境持续监控，每个新 Trace 触发评估
- **DATASET**：预发布回归测试，确保模型更新不引入退化
- **EVENT**：用户反馈驱动，实时收集 thumbs-up/down
- **EXPERIMENT**：离线实验，对比不同 prompt/model 的效果

---

### 6. 智能缓存优化

```typescript
// packages/shared/src/server/evalJobConfigCache.ts
const CACHE_TTL_SECONDS = 600; // 10 分钟

export const hasNoEvalConfigsCache = async (
  projectId: string,
  cacheType: "traceBased" | "eventBased",
): Promise<boolean> => {
  const cacheKey = `langfuse:eval:no-${cacheType}-configs:${projectId}`;
  const cached = await redis.get(cacheKey);
  return Boolean(cached);
};
```

**设计理由**：
- 大部分项目没有激活的 Eval 配置，缓存这一状态可以避免每次 Trace 插入时查询数据库
- 10 分钟 TTL 保证配置更新后的最终一致性

**与 Opik 对比**：
- Opik 的评估器是编程式定义（Python 函数），灵活但难以在 UI 中管理
- Langfuse 的评估器是声明式配置（JSON），可通过 Web UI 可视化编辑和版本控制

---

## Langfuse vs Opik 灵活性对比

| 维度 | Langfuse | Opik | 优势方 |
|------|----------|------|--------|
| **Observation 类型** | 10 种语义类型 | 3 种基础类型 | Langfuse |
| **Eval 配置方式** | 声明式 UI + API | 编程式 Python 函数 | Langfuse（易管理）|
| **数据提取能力** | JSONPath + 多层级映射 | 固定字段访问 | Langfuse |
| **实时评估** | 支持（EVENT 目标） | 支持 | 平局 |
| **回归测试** | 支持（DATASET 目标） | 支持 | 平局 |
| **部署复杂度** | 高（4 组件） | 中（2 组件） | Opik |
| **UI 易用性** | 强（Playground + 直接跳转） | 中 | Langfuse |
| **与框架集成** | Decorators + Auto-instrumentation | Decorators | 平局 |

---

## 核心代码示例

### 基础 Tracing

```python
from langfuse import Langfuse

langfuse = Langfuse()

# 创建 Trace
trace = langfuse.trace(
    name="multi-agent-workflow",
    input={"user_query": "Summarize climate change impacts"},
    tags=["production", "multi-agent"],
)

# 嵌套 Agent Observation
agent_span = trace.agent(
    name="coordinator",
    input={"task": "coordinate"},
)

# 工具调用
agent_span.tool(
    name="web-search",
    input={"query": "climate change 2024"},
    output={"results": [...]},
)

# LLM 生成
generation = agent_span.generation(
    name="summary-gen",
    model="gpt-4",
    input=[{"role": "user", "content": "Summarize..."}],
    output="The impacts include...",
    usage={"prompt_tokens": 120, "completion_tokens": 80},
)

trace.update(output="Final summary delivered")
```

### 声明式 Eval 配置

```typescript
// Web UI 中创建的 Eval Template
{
  "name": "Agent Response Quality",
  "targetObject": "trace",
  "variableMappings": [
    {
      "templateVariable": "input",
      "langfuseObject": "trace",
      "selectedColumnId": "input"
    },
    {
      "templateVariable": "agent_output",
      "langfuseObject": "agent",
      "objectName": "coordinator",
      "selectedColumnId": "output",
      "jsonSelector": "$.summary"
    }
  ],
  "evalPrompt": "Rate the quality of {{agent_output}} for query {{input}}. Score 1-5.",
  "outputSchema": {
    "reasoning": "string",
    "score": "number"
  }
}
```

---

## 最佳实践

1. **为不同语义使用正确的 Observation 类型**
   - 使用 `AGENT` 标记智能决策单元
   - 使用 `EVALUATOR` 记录评估过程本身
   - 使用 `GUARDRAIL` 标记安全检查

2. **利用 JSONPath 实现复杂数据提取**
   - 从嵌套 JSON 中提取特定字段：`$.response.choices[0].message.content`
   - 聚合数组数据：`$.documents[*].score`

3. **分离实时评估和批量评估**
   - 实时：使用 `EVENT` 目标，低延迟反馈
   - 批量：使用 `TRACE` 目标 + 异步 Worker

4. **反模式**：过度细粒度的 Observation
   - 避免为每个函数调用创建 SPAN，会导致 Trace 树过深
   - 建议：只为关键业务逻辑创建 Observation

---

## 关键要点

1. **Langfuse 的灵活性来自其类型系统和变量映射机制**：10 种 Observation 类型 + JSONPath 提取器可以表达任意复杂的评估需求。
2. **生产级架构支持长期运营**：ClickHouse 的列式存储和 Redis 缓存保证了百万级 Trace 的高性能。
3. **声明式配置降低了评估门槛**：非技术人员也可以通过 UI 创建和调整评估器。

---

## 相关文档

- [Opik 与 Bloom 集成方案](./opik-bloom-integration.md) - 比较评估平台的不同应用场景
- [Agent Evaluation 索引](../README.md) - 评估工具概览
- [Langfuse 官方文档](https://langfuse.com/docs)

---

## 参考

- [Langfuse GitHub Repository](https://github.com/langfuse/langfuse)
- [Langfuse Tracing Documentation](https://langfuse.com/docs/tracing)
- [Langfuse Evaluation Guide](https://langfuse.com/docs/evaluation/overview)
- [ClickHouse for Time-Series](https://clickhouse.com/docs/en/guides/developer/time-series/)

---

*创建时间：2026-03-02*
*更新时间：2026-03-02*
