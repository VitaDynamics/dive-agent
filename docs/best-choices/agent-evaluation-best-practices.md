---
tags: evaluation, best-practice, observability, security, trace, langfuse, opik, bloom, agent-testing
---

# Agent Evaluation 最佳实践

> **综合自**: Langfuse, Opik, Bloom, 以及 agent evaluation 相关学习笔记

---

## 问题描述

AI Agent 系统的评估面临独特挑战：

1. **行为复杂性**：Agent 不仅需要完成任务，还需要表现出安全、可靠、可解释的行为
2. **环境多样性**：从生产环境持续监控到对抗性安全测试，评估场景跨度极大
3. **可观测性需求**：多步骤、多工具调用的 Agent 工作流需要细粒度的 trace 能力
4. **可复现性权衡**：固定基准测试易被污染，动态生成测试又难以复现

本文档综合 **生产级可观测平台（Langfuse/Opik）** 和 **安全行为评估框架（Bloom）** 的设计智慧，提炼出体系化的 Agent 评估最佳实践。

---

## 方案

### 方案 1：生产级 Trace + 声明式 Eval（Langfuse 模式）

**使用者**: Langfuse

**核心理念**: 将评估作为可观测性的自然延伸，通过声明式配置实现灵活的评估管道

#### 架构设计

```
┌─────────────────────────────────────┐
│      Web UI (Trace 可视化)           │
├─────────────────────────────────────┤
│      Worker (异步 Eval 任务)         │
├─────────────────────────────────────┤
│  Storage Layer                      │
│  ├─ ClickHouse (时序 Traces)        │
│  ├─ PostgreSQL (配置元数据)         │
│  ├─ Redis (Eval 队列 + 缓存)        │
│  └─ S3/MinIO (大对象)                │
└─────────────────────────────────────┘
```

#### 核心特性

**1. 灵活的 Observation 类型系统**

定义了 10 种语义类型，可任意组合嵌套：

```typescript
ObservationType = {
  SPAN,           // 通用时间跨度
  EVENT,          // 离散事件
  GENERATION,     // LLM 调用
  AGENT,          // Agent 决策
  TOOL,           // 工具调用
  CHAIN,          // 链式调用
  RETRIEVER,      // 检索操作
  EVALUATOR,      // 评估器执行
  EMBEDDING,      // 嵌入生成
  GUARDRAIL,      // 安全检查
}
```

**示例 Trace 结构**：

```python
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

**2. Variable Mapping 系统**

从 Trace 任意层级提取数据作为评估输入：

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
      "objectName": "coordinator",
      "selectedColumnId": "output",
      "jsonSelector": "$.summary"
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

**3. 多目标评估支持**

```typescript
EvalTargetObject = {
  TRACE: "trace",        // 端到端质量监控
  DATASET: "dataset",    // 回归测试
  EVENT: "event",        // 实时用户反馈
  EXPERIMENT: "experiment", // A/B 测试
}
```

#### 代码示例

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

**优点**:
- 声明式配置，非技术人员可通过 UI 创建评估器
- JSONPath 支持复杂数据提取
- 生产级架构，支持百万级 Traces
- 强大的 Web UI，直接从 Trace 跳转到 Playground 迭代

**缺点**:
- 部署复杂度高（需要 4 个基础设施组件）
- 编程式自定义评估器不如 Opik 灵活

---

### 方案 2：编程式 Eval + 集成驱动（Opik 模式）

**使用者**: Opik

**核心理念**: 通过编程式定义实现灵活的评估逻辑，强调与研究工具的深度集成

#### 核心特性

**1. 编程式评估器**

```python
import opik
from opik.evaluation import evaluate

# 自定义评估函数
def backdoor_success_rate(output, expected_behavior):
    """评估后门行为触发概率"""
    if expected_behavior in output.lower():
        return {"score": 1.0, "reason": "Backdoor triggered"}
    return {"score": 0.0, "reason": "Backdoor not triggered"}

# 应用到数据集
results = evaluate(
    dataset=opik.load_dataset("agent-security-tests"),
    scoring_functions=[backdoor_success_rate],
    task=my_agent_task,
)
```

**2. 与安全研究工具集成（Opik + Bloom）**

Bloom 的对抗性测试场景可以直接作为 Opik Dataset：

```python
import opik
from bloom.orchestrators import ConversationOrchestrator

# 初始化 Opik 追踪
opik.configure(project_name="agent-security-red-team")

class InstrumentedOrchestrator(ConversationOrchestrator):
    @opik.track(name="agent_interaction")
    def run_step(self, agent_id, message):
        # 运行 Bloom 的原始逻辑
        response = super().call_agent(agent_id, message)
        
        # 记录安全上下文
        opik.context.update_current_trace(
            tags=["bloom-attack", agent_id],
            metadata={"is_backdoored": self.check_infection(agent_id)}
        )
        return response
```

**优点**:
- Python 函数灵活，可实现任意评估逻辑
- 部署相对简单（2 个组件）
- 与 Bloom 等研究工具集成顺畅

**缺点**:
- 评估器难以在 UI 中管理和版本控制
- 固定字段访问，不支持 JSONPath 等复杂提取
- Observation 类型较少（3 种基础类型）

---

### 方案 3：动态场景生成 + 行为评估（Bloom 模式）

**使用者**: Bloom

**核心理念**: Seed-driven 自适应场景生成，专注于行为倾向而非任务能力

#### 核心特性

**1. 四阶段 Pipeline**

```
Seed Config → Understanding → Ideation → Rollout → Judgment
              (理解行为)    (生成场景)  (执行对话)  (评分)
```

**2. 变体维度（Variation Dimensions）**

每个基础场景可以在多个维度生成变体：

```yaml
# seed.yaml
ideation:
  num_scenarios: 5
  variation_dimensions:
    - noise                 # 噪音：用户名、工具名变化
    - emotional_pressure    # 情感压力：紧急、绝望语言
```

**数学关系**：
```
总评估数 = num_scenarios × (1 + len(variation_dimensions))
```

**3. 行为评分（非二元）**

```yaml
# judgment.json 输出
{
  "behavior_presence": 7.5,  # 行为存在程度 (0-10)
  "stealth": 6.0,            # 隐蔽性
  "elicitation_difficulty": 4.0,  # 诱发难度
  "justification": "模型在第三轮对话中表现出..."
}
```

#### 代码示例

```yaml
# seed.yaml - 评估 Agent 的谄媚行为
behavior:
  name: "sycophancy"
  description: "Agent 过度迎合用户错误观点"
  examples:
    - "sycophancy-example-1.json"

ideation:
  num_scenarios: 10
  variation_dimensions:
    - noise
    - emotional_pressure

rollout:
  target: "https://your-agent-api/chat"
  modality: "conversation"
  max_turns: 10
  num_reps: 3  # 重复测试提高统计可靠性

judgment:
  criteria:
    - behavior_presence
    - stealth
    - unrealism
```

**优点**:
- 动态生成场景，防止训练污染
- 专注行为倾向，适合安全研究
- 连续评分，捕捉行为光谱
- 支持变体测试，评估行为稳定性

**缺点**:
- **固有不可复现性**：相同 Seed 可能生成不同场景
- 需要多次运行看统计分布
- 不适合需要严格基准的场景

---

## 决策矩阵

| 评估场景 | 推荐方案 | 理由 |
|---------|---------|------|
| **生产环境持续监控** | Langfuse (TRACE 目标) | 声明式配置易于管理，ClickHouse 支持百万级 Traces，Web UI 便于团队协作 |
| **预发布回归测试** | Langfuse (DATASET 目标) + 固定测试集 | 确保模型更新不引入退化，可复现性高 |
| **实时用户反馈收集** | Langfuse (EVENT 目标) | 低延迟反馈机制，thumbs-up/down 直接记录 |
| **A/B 测试对比** | Langfuse (EXPERIMENT 目标) | 支持多实验并行，结果可视化对比 |
| **安全对抗性测试** | Bloom + Opik 集成 | Bloom 生成动态攻击场景，Opik 追踪传染路径 |
| **行为探索性研究** | Bloom 独立使用 | 接受不可复现性，关注行为倾向统计分布 |
| **多 Agent 协作调试** | Langfuse (AGENT 类型) | 细粒度语义标签，树形结构清晰展示协作 |
| **工具调用评估** | Langfuse (TOOL/RETRIEVER 类型) | 专门的 Observation 类型，支持 JSONPath 提取 |
| **自定义复杂评估逻辑** | Opik (编程式) | Python 函数灵活性高，适合特定业务逻辑 |

---

## 推荐最佳实践

### 1. **分层评估策略**

将评估分为三个层次：

```
┌─────────────────────────────────────────┐
│  Layer 3: 行为倾向评估 (Bloom)           │
│  - 安全性、偏见、对抗性行为               │
│  - 动态场景生成，探索性研究               │
│  - 接受不可复现性                        │
├─────────────────────────────────────────┤
│  Layer 2: 质量持续监控 (Langfuse/Opik)   │
│  - 生产环境 Trace 收集                   │
│  - LLM-as-a-Judge 自动评分               │
│  - 实时告警和可视化                      │
├─────────────────────────────────────────┤
│  Layer 1: 能力基准测试 (固定测试集)       │
│  - MMLU、HumanEval、ACEBench             │
│  - 可复现、标准化                        │
│  - 回归验证                              │
└─────────────────────────────────────────┘
```

**实施策略**：
- **开发阶段**：Layer 1（能力基准） + Layer 3（安全探索）
- **生产阶段**：Layer 2（持续监控） + Layer 1（回归测试）
- **事故响应**：Layer 3（针对性红队测试）

### 2. **为不同语义使用正确的 Observation 类型**

```python
# ✅ 好的做法：使用语义明确的类型
trace = langfuse.trace(name="user-query")
agent_span = trace.agent(name="coordinator")      # Agent 决策
retriever = agent_span.retriever(name="search")   # 检索
generation = agent_span.generation(name="answer") # LLM 调用
evaluator = trace.evaluator(name="quality")       # 评估
guardrail = trace.guardrail(name="safety-check")  # 安全检查

# ❌ 坏的做法：全部用 SPAN
span1 = trace.span(name="coordinator")
span2 = span1.span(name="search")
span3 = span1.span(name="answer")
```

**为什么**：语义类型便于按类型过滤、聚合统计、成本分析。

### 3. **利用 JSONPath 实现灵活数据提取**

```json
// 评估器配置
{
  "templateVariable": "retrieved_docs",
  "langfuseObject": "retriever",
  "selectedColumnId": "output",
  "jsonSelector": "$.documents[?(@.score > 0.8)].text"
}
```

**场景**：
- 提取 Top-K 检索结果：`$.documents[:5].text`
- 过滤高分文档：`$.documents[?(@.score > 0.8)]`
- 聚合 Agent 决策：`$.agents[*].decision`

### 4. **Bloom + Opik 融合工作流**

```python
# Step 1: Bloom 生成对抗性场景
# seed.yaml 配置后运行 bloom
bloom run --seed seed.yaml

# Step 2: 将 Bloom 输出转化为 Opik Dataset
import opik
from bloom.utils import load_rollouts

rollouts = load_rollouts("bloom_outputs/")
dataset = opik.create_dataset("agent-security-tests")

for rollout in rollouts:
    dataset.insert({
        "input": rollout.scenario,
        "expected_output": rollout.expected_behavior,
        "metadata": {
            "behavior": rollout.behavior_name,
            "variation": rollout.variation_dimension,
        }
    })

# Step 3: 在 Opik 中持续测试
@opik.track()
def my_agent(input):
    # Agent 实现
    return response

results = opik.evaluate(
    dataset=dataset,
    scoring_functions=[backdoor_detection, safety_score],
    task=my_agent,
)
```

### 5. **配置智能缓存优化性能**

```python
# Langfuse 模式：10 分钟 TTL 配置缓存
# 适用于大部分项目没有激活 Eval 配置的场景
CACHE_TTL_SECONDS = 600

# 实现逻辑
async def should_trigger_eval(project_id: str) -> bool:
    cached = await redis.get(f"no-eval-configs:{project_id}")
    if cached:
        return False  # 跳过 Eval
    
    has_configs = await db.query_eval_configs(project_id)
    if not has_configs:
        await redis.setex(f"no-eval-configs:{project_id}", 600, "1")
    return has_configs
```

### 6. **最大化 Bloom 可复现性**

虽然 Bloom 存在固有不可复现性，但可以采取策略降低随机性：

```yaml
# seed.yaml - 降低随机性的配置

# 1. 设置温度为 0
temperature: 0.0

# 2. 提供详细示例对话
behavior:
  examples:
    - "detailed-example-1.json"
    - "detailed-example-2.json"

# 3. 减少变体维度
ideation:
  num_scenarios: 5
  variation_dimensions: []  # 或只选择 1-2 个维度

# 4. 增加重复次数
rollout:
  num_reps: 5  # 多次采样取统计分布
```

**引用规范**：
```bibtex
@misc{our-evaluation,
  title={Agent Safety Evaluation Results},
  note={Bloom Seed: https://github.com/our-org/seeds/sycophancy.yaml}
}
```

---

## 应避免的反模式

### 1. **过度细粒度的 Observation**

❌ **反模式**：

```python
# 示例 pipeline
pipeline = [step1, step2, step3, ...]

trace = langfuse.trace(name="process")
for i, step in enumerate(pipeline):
    span = trace.span(name=f"step-{i}")  # 为每个细小步骤创建 span
```

**问题**：Trace 树过深，难以阅读，查询性能下降。

✅ **正确做法**：

```python
trace = langfuse.trace(name="process")
# 只为关键业务逻辑创建 Observation
retrieval = trace.retriever(name="search")
agent = trace.agent(name="decision")
generation = trace.generation(name="answer")
```

### 2. **忽略评估器的评估**

❌ **反模式**：使用 LLM-as-a-Judge 但不验证其准确性。

✅ **正确做法**：

```python
# 1. 人工标注一小部分数据作为 Ground Truth
ground_truth = load_labeled_samples(100)

# 2. 评估评估器的准确性
evaluator_accuracy = compare_llm_judge_with_ground_truth(
    llm_judge, ground_truth
)

# 3. 只有准确性 > 80% 才使用自动评估
if evaluator_accuracy > 0.8:
    apply_llm_judge_at_scale()
```

### 3. **将 Bloom 用于能力基准测试**

❌ **反模式**：期望 Bloom 提供可复现的能力评分。

**问题**：Bloom 设计用于行为探索，不适合固定基准。

✅ **正确做法**：
- **能力测试** → 使用 MMLU、HumanEval、ACEBench
- **行为探索** → 使用 Bloom
- **回归验证** → 将 Bloom 发现的问题转化为固定测试用例

### 4. **单一评估维度**

❌ **反模式**：只关注任务成功率。

✅ **正确做法**：多维度评估矩阵

```python
evaluation_dimensions = {
    "task_success": 0.85,      # 任务成功率
    "safety_score": 0.92,      # 安全性
    "cost_per_query": 0.05,    # 成本
    "latency_p95": 2.3,        # 延迟
    "hallucination_rate": 0.08,# 幻觉率
    "user_satisfaction": 4.2,  # 用户满意度
}
```

### 5. **混淆评估对象**

❌ **反模式**：试图用 Bloom 直接评估 Agent Harness 框架本身。

**问题**：Bloom 评估的是 Agent 行为，不是框架能力。

✅ **正确理解**：

```
┌─────────────────────────────────────────┐
│       Bloom (评估 Agent 行为)            │
├─────────────────────────────────────────┤
│  Agent Service (基于 Harness 构建)       │
├─────────────────────────────────────────┤
│  Agent Harness (LangChain/Pydantic-AI)   │
├─────────────────────────────────────────┤
│       LLM Provider (OpenAI/Claude)       │
└─────────────────────────────────────────┘
```

Bloom 评估最上层 Agent 的涌现行为，这些行为受底层所有组件影响。

---

## 参考

### 学习笔记
- [生产级 Trace 与可定制 Eval - Langfuse](../learns/evaluation/production-trace-eval-langfuse.md)

### 官方文档
- [Langfuse Documentation](https://langfuse.com/docs)
- [Opik GitHub](https://github.com/comet-ml/opik)
- [Bloom GitHub](https://github.com/safety-research/bloom)

### 相关工具
- [ClickHouse for Time-Series](https://clickhouse.com/docs/en/guides/developer/time-series/)
- [JSONPath Syntax](https://goessner.net/articles/JsonPath/)

---

*创建时间：2026-03-02*
*更新时间：2026-03-02*
