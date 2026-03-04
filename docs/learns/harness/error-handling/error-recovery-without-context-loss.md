---
tags: error-handling, resilience, context-management, architecture, harness, comparison
---

# LLM 抽象层错误恢复与上下文无损设计

> **范围**：深入探讨 LLM 抽象层如何在发生网络错误、流中断或模型异常时实现自动化恢复，并确保对话上下文（History/State）不丢失。
>
> **综合自**：republic, codex, pydantic-ai, langchain, kimi-cli (kosong)
>
> **优先级**：P0

---

## 概述

在构建生产级 AI Agent 时，最脆弱的环节通常是 **LLM 调用过程中的异常恢复**。传统的简单重试往往会导致：
1. **上下文丢失**：重试时无法还原之前的中间状态（如已生成的思考过程或部分工具调用）。
2. **状态不一致**：重试产生的重复消息或残缺消息污染了对话历史。
3. **性能损耗**：由于缺乏有效的 Checkpoint，重试必须从头开始，浪费 Token 和时间。

本文总结了主流 Agent 框架解决这些问题的核心设计模式。

---

## 核心设计模式：上下文无损三要素

### 1. 不可变证据链 (Immutable Tape Pattern)
**代表框架**：`republic`

核心哲学是“历史是神圣不可侵犯的证据”。
- **机制**：所有的消息、工具调用、结果、甚至错误都被记录在一个**追加式（Append-only）的磁带 (Tape)** 中。
- **优点**：即使请求失败，磁带依然完整记录了失败前的所有状态。重试时，逻辑层只需根据磁带内容重新构建 Prompt。
- **实现建议**：使用 `TapeEntry` 结构体，包含 `kind` (message, tool_call, error, etc.) 和 `payload`。

### 2. 状态快照与检查点 (State Snapshot & Checkpoint)
**代表框架**：`kimi-cli`, `pydantic-ai`

- **机制**：在关键路径（如用户输入后、工具执行后）自动创建 **Checkpoint**。
- **恢复**：发生不可恢复错误时，支持 `revert_to(checkpoint_id)` 回滚到上一个稳定状态，而不是清空整个会话。
- **实现建议**：定义 `StateSnapshot` trait，支持序列化/反序列化和状态回滚。

### 3. 解耦的上下文视图 (Decoupled Context Window)
**代表框架**：`republic`, `pi-mono`

- **机制**：将**物理存储（完整历史）**与**逻辑视图（发送给 LLM 的内容）**解耦。
- **策略**：使用 **Anchor (锚点)** 定位历史起点，并使用 **Select Hook (过滤器)** 在构建 Prompt 时动态剔除冗余信息（如重复读取文件、过期的中间思考）。
- **优点**：错误恢复时可以动态调整视图，例如“重试时只带上最近 5 条消息”以规避上下文溢出。

---

## 框架实现深度对比

### 1. Codex: 传输层粘性回退与流中断恢复

Codex 在 Rust 实现中展示了极致的健壮性：
- **流中断识别**：定义特定的 `Stream` 错误，专门处理 SSE/WebSocket 在 `response.completed` 之前断开的情况。
- **粘性回退 (Sticky Fallback)**：WebSocket 多次重试失败后自动回退到 HTTP，并在整个 Session 期间保持 HTTP，避免反复失败。
- **隐形重试**：为了用户体验，Release 模式下隐藏首次网络波动引起的重试通知。

### 2. Pydantic-AI: 结构化重试与 Retry-After 支持

- **HTTP 级重试**：基于 `tenacity` 实现了尊重 `Retry-After` 响应头的等待策略（支持秒数和 HTTP Date 转换）。
- **模型级 Fallback**：支持 `FallbackModel`，当 A 模型超时或报错时，透明切换到 B 模型。
- **Agent 状态关联**：重试计数器（`retries`）直接存储在 `GraphAgentState` 中，确保重试逻辑与业务流程紧密耦合。

### 3. Kimi-CLI (Kosong): 增量合并与文件后端

- **增量合并 (Mergeable)**：流式接收片段时，实时合并到 `PendingPart`。如果流中断，由于片段已合并到内存消息对象中，可以轻松保存当前进度。
- **文件检查点**：`Context` 会将历史异步刷新到 JSONL 文件，并插入特殊的 `_checkpoint` 标记，确保进程重启后上下文依然可恢复。

---

## 最佳实践指南

### 1. 错误分类体系
不要盲目重试。将错误分为：
- **可重试 (Transient)**：429 (Rate Limit), 500/502/503/504 (Server Error), Network Timeout, Stream Interruption。
- **需干预 (Actionable)**：401 (Auth), 400 (Invalid Request), Context Window Exceeded (需要压缩上下文)。
- **不可恢复 (Fatal)**：403 (Forbidden), Quota Exceeded。

### 2. 无损恢复工作流
1. **捕获异常**：保留原始 `RequestID` 和错误上下文。
2. **状态保留**：将已收到的部分响应（如有）存入备选历史。
3. **退避等待**：采用指数退避（2, 4, 8, 16s...）并加随机抖动（Jitter）。
4. **视图调整**：如果错误原因是上下文溢出，触发 `Compaction` (压缩) 逻辑再重试。
5. **切换通道**：如果 WebSocket 持续失败，降级到标准 HTTPS 请求。

### 3. 示例：理想的 Rust LLM 错误处理结构

```rust
pub enum RecoveryAction {
    Retry { delay: Duration },
    Fallback { model: String },
    CompactAndRetry,
    Abort(String),
}

impl LLMClient {
    pub async fn call_with_resilience(&self, request: Request) -> Result<Response> {
        let mut attempts = 0;
        loop {
            match self.execute(&request).await {
                Ok(resp) => return Ok(resp),
                Err(e) => {
                    attempts += 1;
                    match self.policy.decide(e, attempts) {
                        RecoveryAction::Retry { delay } => sleep(delay).await,
                        RecoveryAction::Fallback { model } => {
                            let mut new_req = request.clone();
                            new_req.model = model;
                            return self.execute(&new_req).await;
                        }
                        RecoveryAction::Abort(msg) => return Err(anyhow!(msg)),
                        // ...
                    }
                }
            }
        }
    }
}
```

---

## 关键要点

1. **解耦存储与视图**：是防止上下文丢失的核心。物理历史永远追加，逻辑 Prompt 动态生成。
2. **识别流中断**：流式 API 的中断不应被视为普通网络错误，而应支持从最后一个成功片段（或重启当前轮次）恢复。
3. **粘性降级**：不要在同一个 Session 里反复尝试已知失败的连接方式（如 WebSocket）。
4. **尊重协议**：严格遵守服务端提供的 `Retry-After` 指令，这是防止被封禁的最佳方式。

---

## 相关文档

- [Codex 错误处理与流中断恢复](./codex-error-handling-stream-interruption.md)
- [结构化错误分类与自动重试](./structured-errors-retry.md)
- [状态快照模式与双模并发](../concurrency/state-snapshot-concurrency.md)
- [Republic Anchor 与上下文隔离](../architecture/republic-anchor-mechanism.md)

---

*创建时间：2026-03-04*
*更新时间：2026-03-04*
