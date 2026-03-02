# Agent Group 知识库

> Agent 框架、评估工具、训练方法和学习资源的精选集合。

## 概述

本仓库作为集中式知识库，包含：
- **仓库索引**：按类别组织的 Agent 相关项目精选列表
- **学习笔记**：Agent 框架模式的深度分析和比较
- **最佳实践**：设计决策和架构建议

## 仓库分类

| 类别 | 描述 | 数量 |
|------|------|------|
| [Agent](./repos/agent/) | 独立的 AI Agent 应用和实现 | 0 |
| [Agent-harness](./repos/agent-harness/) | Agent 框架和编排工具 | 6 |
| [Agent Evaluation](./repos/agent-evaluation/) | Agent 测试和评估框架 | 0 |
| [Agent Training](./repos/agent-training/) | Agent 训练和微调资源 | 0 |

**[查看所有仓库 →](./repos/README.md)**

## 文档

### 学习笔记（按主题）

| 主题 | 描述 | 文档数 |
|------|------|--------|
| [流式处理](./docs/learns/streaming/) | 异步流式、WebSocket 模式 | 4 |
| [错误处理](./docs/learns/error-handling/) | 结构化错误、重试策略 | 1 |
| [上下文管理](./docs/learns/context-management/) | 会话历史、上下文转换 | 3 |
| [类型安全](./docs/learns/type-safety/) | 类型安全的消息层次结构 | 1 |
| [中间件](./docs/learns/middleware/) | 回调和可扩展性系统 | 1 |
| [并发](./docs/learns/concurrency/) | 状态快照和并发模式 | 1 |
| [架构](./docs/learns/architecture/) | 框架架构分析 | 2 |
| [抽象层](./docs/learns/abstractions/) | LLM 抽象层比较 | 3 |
| [WebSocket](./docs/learns/websocket/) | OpenAI WebSocket 比较 | 1 |

### 最佳实践

综合多个框架的最佳实践文档。

| 文档 | 描述 |
|------|------|
| [LLM 错误处理设计](./docs/best-choices/llm-error-handling-design.md) | 结构化错误分类、重试策略 |
| [流式拉取防抖推送设计](./docs/best-choices/streaming-pull-debounced-push-design.md) | 流式架构模式 |

**[查看所有文档 →](./docs/README.md)**

## 快速链接

- [贡献指南](./CONTRIBUTING.md)
- [添加仓库](../../issues/new?template=add-repository.yml)
- [贡献文档](../../issues/new?template=document-contribution.yml)
- [GitHub Wiki](../../wiki)（从 `docs/learns/` 自动同步）
- [讨论区](../../discussions)

## 同步源码

克隆外部仓库用于本地学习：

```bash
# 同步所有仓库（浅层克隆）
./scripts/sync-sources.sh

# 同步单个仓库
./scripts/sync-sources.sh pydantic-ai

# 查看同步状态
./scripts/sync-sources.sh --status
```

克隆的代码存储在 `sources/<类别>/<名称>/`（不提交到 git）。

## 统计信息

```
仓库：6（Agent-harness: 6, Evaluation: 0, Training: 0）
文档：17 个学习笔记 + 2 个最佳实践文档
主题：9
最后更新：2026-03-02
```

---

*由 Agent Group 团队维护*
