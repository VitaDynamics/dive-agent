# Agent Evaluation 学习笔记

Agent 性能测试、安全性评估和基准测试框架的模式分析。

---

## 定义

Agent Evaluation 涵盖：
- **基准测试**：Agent 评估的标准化任务和指标
- **安全性测试**：对抗性测试、红队测试、后门检测
- **性能监控**：运行时可观测性和性能跟踪
- **行为分析**：Agent 决策过程的可解释性

---

## 已索引主题

| 主题 | 描述 | 文档数 |
|------|------|--------|
| [Seed-driven Evaluation](./seed-driven-evaluation/) | 基于 Seed 的自适应行为评估模式 | 1 |
| Production Tracing & Eval | 生产级 trace 与可定制评估方案 | 1 |

### 其他文档

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [Opik Bloom 集成](./opik-bloom-integration.md) | 评估框架与观测平台集成，Bloom 后门检测与 Opik 可观测性结合 | P1 |

---

## 建议添加的主题

| 主题 | 描述 | 潜在来源 |
|------|------|----------|
| seed-driven-evaluation | Seed-driven 自适应行为评估 | bloom |
| benchmarks | 标准化基准测试框架 | agent-bench, SWE-bench |
| adversarial-testing | 对抗性测试方法 | 各框架安全测试 |
| performance-metrics | 性能指标和评估维度 | 通用 |

---

## 相关仓库

| 仓库 | 描述 |
|------|------|
| [bloom](../../../repos/agent-evaluation/) | Backdooring LLMs for multi-agent environments |
| [langfuse](../../../repos/agent-evaluation/) | 生产级 trace + 可定制 eval 长期方案 |

---

## 添加笔记

1. 在相应主题子目录下创建文档
2. 遵循 [学习笔记模板](../../templates/learning-note-template.md)
3. 使用标签：`evaluation`, `<主题>`
4. 更新本 README 索引
5. 更新 [主索引](../README.md)

### 示例

添加 bloom 的后门检测分析：

```bash
mkdir -p docs/learns/evaluation/backdoor-detection
# 创建 bloom-backdoor-analysis.md
```

---

**[查看贡献指南 →](../../../CONTRIBUTING.md)**

---

*最后更新：2026-03-04*
