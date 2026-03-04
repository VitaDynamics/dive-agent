# 错误处理

Agent 框架的错误处理、重试策略和弹性模式。

## 定义

错误处理涵盖：
- **错误分类**：可重试 vs 不可重试错误
- **重试策略**：指数退避、熔断器模式
- **错误传播**：从底层到 UI 的错误转换
- **恢复机制**：流中断恢复、会话恢复

## 学习笔记

| 文档 | 描述 | 优先级 |
|------|------|--------|
| [结构化错误与重试](./structured-errors-retry.md) | LangChain 中的错误分类、重试策略和恢复模式 | P1 |
| [Codex 错误处理与流中断](./codex-error-handling-stream-interruption.md) | Codex 的错误分类、可重试性判断、WebSocket 回退、流中断恢复 | P1 |

## 建议添加的主题

| 主题 | 描述 | 潜在来源 |
|------|------|----------|
| pydantic-ai-errors | Pydantic AI 的验证错误处理 | pydantic-ai |

## 添加笔记

1. 在 `docs/learns/harness/error-handling/` 创建新文档
2. 遵循 [学习笔记模板](../../../templates/learning-note-template.md)
3. 使用标签：`error-handling`, `retry`, `resilience`
4. 更新本 README

---

*最后更新：2026-03-04*
