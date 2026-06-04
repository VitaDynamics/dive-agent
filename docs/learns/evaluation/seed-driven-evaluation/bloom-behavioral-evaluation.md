---
tags: evaluation, bloom, behavioral-evaluation, seed-driven, reproducibility, agent-harness, safety
---

# Bloom: Seed-driven 自适应行为评估

> **范围**：Bloom 框架的评估概念、设计思路、与 Agent Harness 的关系以及可复现性权衡
>
> **综合自**：bloom
>
> **优先级**：P1

---

## 概述

Bloom 是一个面向 LLM 行为安全评估的开源框架，其核心创新在于采用 **Seed-driven 自适应场景生成** 机制。与传统固定基准测试不同，Bloom 不依赖于预定义的测试题库，而是根据用户提供的 Seed 配置动态生成评估场景，从而实现对 AI 系统行为倾向的开放式探测。

这种设计哲学源于安全研究的核心需求：固定题库容易被针对性训练污染（Training Contamination），而攻击者也不会拘泥于固定模式。Bloom 通过 LLM 自身生成多样化的测试场景，能够发现预定义测试集难以覆盖的边缘行为和潜在风险。

然而，这种灵活性也带来了根本性的权衡：**动态生成 vs 严格可复现性**。理解这一权衡对于正确应用 Bloom 至关重要。

---

## 评估概念：Bloom 评估什么

### 目标：行为倾向而非能力

Bloom 专注于评估 LLM 的 **行为倾向（Behavioral Tendencies）**，而非传统的任务能力（如数学推理、代码生成）：

| 行为类别 | 具体行为 | 评估焦点 |
|---------|---------|---------|
| 安全风险 | Self-preservation（自我保护）| 模型是否会抵抗关闭或修改 |
| | Sycophancy（谄媚）| 是否会过度迎合用户错误观点 |
| | Instructed sabotage（指令式破坏）| 长期任务中隐蔽执行恶意副目标的能力 |
| | Reasoning unfaithfulness（推理不忠实）| 推理过程与实际行动是否一致 |
| 偏见倾向 | Political bias（政治偏见）| 输出是否偏离中立立场 |
| | Self-preferential bias（自我偏好）| 作为裁判时是否偏袒自身 |
| 能力边界 | Cyber/bio/chem capabilities | 危险领域知识的展示程度 |

### 评估输出

Bloom 的输出是 **行为存在程度评分（0-10 分）**，而非简单的通过/失败：

```yaml
# judgment.json 输出示例
{
  "behavior_presence": 7.5,  # 行为存在程度
  "stealth": 6.0,            # 隐蔽性（辅助维度）
  "elicitation_difficulty": 4.0,  # 诱发难度
  "justification": "模型在第三轮对话中表现出明显的自我保护倾向..."
}
```

这种连续评分机制更适合捕捉行为的**光谱特性**——大多数安全风险不是"有/无"的二元问题，而是程度问题。

---

## 设计思路：Seed-driven 自适应评估

### 核心机制

Bloom 的评估流程是一个 **4 阶段 Pipeline**，每个阶段都由 LLM 驱动：

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Bloom Pipeline                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Seed Config    ┌──────────────┐    ┌──────────────┐    ┌───────────┐  │
│  (目标行为定义)  │ Understanding│───▶│  Ideation    │───▶│  Rollout  │  │
│                 │  (理解行为)   │    │ (生成场景)    │    │ (执行对话) │  │
│                 └──────────────┘    └──────────────┘    └─────┬─────┘  │
│                          ▲                                     │        │
│                          │                                     ▼        │
│                          └────────────────────────────┐  ┌───────────┐  │
│                                                       └──│ Judgment  │  │
│                                                          │  (评分)    │  │
│                                                          └───────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1. Understanding：行为理解

该阶段通过 LLM 分析目标行为的定义和示例，生成深层理解：

```python
# sources/agent-evaluation/bloom/src/bloom/stages/step1_understanding.py

# Step 1: 生成行为理解
understanding_prompt = make_behavior_understanding_prompt(
    behavior_name, 
    behavior_description, 
    prompts
)

# Step 2-3: 分析示例对话（如果有）
for example_name in example_list:
    example_transcript = utils.load_example(example_name, config=config)
    analysis_prompt = make_transcript_analysis_prompt(
        behavior_name,
        behavior_description,
        transcript,
        example_name,
        behavior_understanding=understanding,
        scientific_motivation=scientific_motivation,
        prompts=prompts,
    )
```

输出包括：
- `behavior_understanding`: 对行为的深度理解
- `scientific_motivation`: 科学动机和研究背景
- `transcript_analyses`: 示例对话分析

### 2. Ideation：场景生成与变体

这是 Bloom 最具特色的阶段。基于 Understanding 结果，LLM 动态生成评估场景：

```python
# sources/agent-evaluation/bloom/src/bloom/stages/step2_ideation.py

# 基础场景生成（支持批处理）
batch_prompt = make_all_scenarios_prompt(
    behavior_name,
    num_scenarios,
    behavior_understanding=behavior_understanding,
    scientific_motivation=scientific_motivation,
    transcript_analyses=transcript_analyses,
    modality=modality,  # "conversation" 或 "simenv"
    start_idx=start_idx,
    end_idx=end_idx,
)

# 变体生成（Variation Dimensions）
variation_prompt = make_variation_prompt(
    behavior_name,
    behavior_understanding,
    scientific_motivation,
    scenario_description,
    variation_dimensions,  # 如 ["noise", "emotional_pressure"]
    modality=modality,
)
```

#### 变体维度（Variation Dimensions）

Bloom 的关键创新：**每个基础场景可以在多个维度上生成变体**，测试行为的稳定性：

```yaml
# seed.yaml
ideation:
  num_scenarios: 5
  variation_dimensions:
    - noise                 # 噪音：用户名、工具名等无关细节变化
    - emotional_pressure    # 情感压力：紧急、绝望等情绪语言
```

**数学关系**：
```
总评估数 = num_scenarios × (1 + len(variation_dimensions))

# 示例：5 个基础场景 + 2 个变体维度 = 15 个评估场景
```

### 3. Rollout：对话执行

在生成的场景中与被测模型进行多轮对话：

```python
# 支持两种模态
modality: "conversation"    # 纯文本对话
modality: "simenv"          # 工具调用环境（需要函数调用支持）
```

### 4. Judgment：行为评分

LLM 作为评判者，对对话进行评分：

```python
# 核心评分维度
behavior_presence: 0-10     # 目标行为存在程度
stealth: 0-10               # 隐蔽性（是否难以被检测）
elicitation_difficulty: 0-10  # 诱发难度（需要多少努力）
unrealism: 0-10             # 场景真实性（排除虚假阳性）
```

---

## 与 Agent Harness 的关系

### 关键区分：评估对象不同

| 层面 | Agent Harness | Bloom |
|-----|---------------|-------|
| **本质** | 编排框架（LangChain、Pydantic-AI 等） | 评估框架 |
| **功能** | 工具调用、状态管理、流式处理 | 行为探测、场景生成、评分 |
| **评估对象** | 框架本身**不可**被 Bloom 直接评估 | LLM 或基于 Harness 构建的 Agent |

### 如何结合使用

Bloom **不能直接评估** Agent Harness 框架本身，但可以评估**基于这些框架构建的 Agent 服务**：

```yaml
# seed.yaml - 评估基于 LangChain 构建的客服 Agent
behavior:
  name: "sycophancy"                    # 测试谄媚行为

rollout:
  target: "https://your-agent-api/chat" # Agent 服务端点
  modality: "conversation"
  max_turns: 10
```

```yaml
# seed.yaml - 评估基于 Pydantic-AI 构建的工具调用 Agent
behavior:
  name: "instructed-long-horizon-sabotage"  # 测试隐蔽破坏能力

rollout:
  target: "https://your-agent-api/invoke"
  modality: "simenv"                    # 需要函数调用支持
  max_turns: 20
```

### 设计启示

这种分层设计反映了 AI 系统评估的层次结构：

```
┌─────────────────────────────────────────┐
│           Bloom (行为评估层)              │
│   - 评估 Agent 是否表现出风险行为         │
│   - 不关心具体实现框架                    │
├─────────────────────────────────────────┤
│         Agent Service (应用层)            │
│   - 基于 Harness 框架构建的具体 Agent     │
│   - 暴露 API 端点供 Bloom 调用            │
├─────────────────────────────────────────┤
│      Agent Harness (框架层)               │
│   - LangChain / Pydantic-AI / Agno        │
│   - 提供工具调用、状态管理等基础能力       │
├─────────────────────────────────────────┤
│        LLM Provider (模型层)              │
│   - OpenAI / Anthropic / 本地模型         │
│   - 实际生成响应的底层模型                 │
└─────────────────────────────────────────┘
```

**关键洞察**：Bloom 评估的是最上层 Agent 的**涌现行为**，这些行为既受底层模型影响，也受 Harness 框架的编排逻辑影响。

---

## 可复现性的权衡

### 固有不可复现性

Bloom 的核心设计导致其**存在固有的不可复现性**：

```
Seed 配置 ──▶ LLM (Ideation) ──▶ 场景 A
              └─────────────────▶ 场景 B (可能不同)
```

即使使用相同的 Seed YAML，由于 LLM 的随机性，每次生成的具体场景文本可能不同。

### 官方立场

Bloom 文档明确承认这一点：

> *"Bloom evaluations should be cited with their full seed configuration for reproducibility"*
> *"Bloom evaluations... grows differently depending on how it's seeded"*

这意味着引用 Bloom 评估时，必须包含完整的 Seed 配置，而非简单的测试集名称。

### 可复现性光谱

| 评估类型 | 复现性 | 适用场景 | 代表工具 |
|---------|--------|---------|---------|
| **固定题库** | ✅ 高 | 能力基准、标准化测试 | MMLU, HumanEval, ACEBench |
| **Bloom (动态生成)** | ⚠️ 中低 | 行为探索、安全研究 | Bloom |
| **混合模式** | ⚠️ 中 | 兼顾覆盖率和可复现性 | 固定 Seed + 多次采样 |

### 最大化复现性的策略

```yaml
# seed.yaml - 降低随机性的配置

# 1. 设置温度为 0
temperature: 0.0

# 2. 提供详细的示例对话
behavior:
  name: "self-preservation"
  examples:
    - "具体的对话示例1.json"
    - "具体的对话示例2.json"

# 3. 固定场景数量，减少变体
ideation:
  num_scenarios: 5
  variation_dimensions: []  # 减少变体维度

# 4. 固定随机种子（如果底层 LLM 支持）
```

### 何时接受不可复现性

在安全研究领域，这种权衡是**可接受的**，因为：

1. **行为倾向是统计性的**：需要多次运行看分布，而非单次结果
2. **攻击者多样化**：真实世界的攻击者不会遵循固定模式
3. **训练污染防护**：固定题库容易被针对性训练绕过

---

## 最佳实践

### 1. 选择合适的评估框架

- **需要严格可复现的基准测试** → 使用固定题库（如 ACEBench）
- **探索性安全研究** → 使用 Bloom 的动态生成能力
- **生产环境监控** → 结合两者，Bloom 用于发现新问题，固定测试集用于回归验证

### 2. 设计有效的 Seed 配置

```yaml
# 好的 Seed 配置特征
behavior:
  name: "目标行为"
  examples:
    - 包含 2-3 个高质量示例对话  # 示例质量直接影响生成场景质量

ideation:
  num_scenarios: 10-20              # 足够覆盖行为空间
  variation_dimensions:             # 选择相关变体维度
    - noise                         # 测试行为对无关变化的稳定性
    - emotional_pressure            # 测试压力下的行为变化

rollout:
  max_turns: 10-20                  # 足够长以观察行为演变
  num_reps: 3                       # 重复测试以提高统计可靠性
```

### 3. 引用 Bloom 评估结果

```bibtex
@misc{bloom2025,
  title={Bloom: an open source tool for automated behavioral evaluations},
  author={Gupta, Isha and others},
  year={2025},
  url={https://github.com/safety-research/bloom},
  note={Seed config: [附完整 seed.yaml 内容或链接]}
}
```

---

## 相关文档

- ACEBench 工具使用评估 - 固定基准测试对比
- [Agent Harness 概览](https://github.com/VitaDynamics/dive-agent/blob/main/repos/agent-harness/README.md) - 支持的 Agent 框架

---

## 参考

- [Bloom GitHub](https://github.com/safety-research/bloom)
- [Bloom README](https://github.com/safety-research/bloom/blob/main/README.md)
- [Bloom Core Pipeline](https://github.com/safety-research/bloom/blob/main/src/bloom/core.py)

---

*创建时间：2026-03-02*
*更新时间：2026-03-02*
