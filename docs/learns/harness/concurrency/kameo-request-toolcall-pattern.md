---
tags: kameo, actor, request-pattern, tool-call, async, concurrency, blocking
---

# Kameo Request 设计与 Tool Call 模式对比

> **范围**：分析 Kameo Actor 框架的 Request 同步等待模式，对比阻塞式与异步式 Tool Call，探讨两个 Agent 作为 Actor 时的交互设计
>
> **综合自**：kameo
>
> **优先级**：P1

---

## 概述

在 Agent 系统中，工具调用（Tool Call）是核心交互模式。当两个 Agent 都是 Actor 时，如何设计它们之间的调用关系成为关键问题。Kameo 作为 Rust Actor 框架，提供了多种请求模式（Ask/Tell/Forward），这些模式与传统的阻塞式/异步式 Tool Call 有着有趣的对应关系。

本文分析：
1. Kameo 的 Request 设计原理
2. 阻塞式 vs 异步式 Tool Call 的语义差异
3. Actor-to-Actor 调用时的设计考量
4. 死锁避免策略

---

## 问题描述

当 Agent A 需要调用 Agent B 的工具时，面临以下决策：

| 场景 | 问题 |
|------|------|
| 阻塞等待 | Agent A 暂停处理其他消息，直到 B 返回结果 |
| 异步继续 | Agent A 继续处理其他任务，如何获取结果？ |
| 双向调用 | A 调用 B，B 又需要调用 A，如何避免死锁？ |
| 超时处理 | 工具执行时间过长，如何优雅处理？ |

Kameo 的 Actor 模型通过邮箱（Mailbox）和消息传递天然地处理了这些问题，但需要正确选择模式。

---

## 核心概念

### 1. Kameo Request 模式

#### Ask 模式（同步等待）

```rust
// Actor A 调用 Actor B，等待回复
let result = actor_b.ask(ToolRequest { param: "data" }).await?;
```

**实现机制**（`src/request/ask.rs`）：

```rust
pub struct AskRequest<'a, A, M, Tm, Tr> {
    actor_ref: &'a ActorRef<A>,
    msg: M,
    mailbox_timeout: Tm,  // 邮箱容量等待超时
    reply_timeout: Tr,     // 回复等待超时
}

// 发送并等待回复
pub async fn send(self) -> Result<<A::Reply as Reply>::Ok, SendError<...>> {
    let (reply, rx) = oneshot::channel();  // 创建一次性通道

    // 将消息包装为 Signal 发送到目标 Actor 邮箱
    let signal = Signal::Message {
        message: Box::new(self.msg),
        actor_ref: self.actor_ref.clone(),
        reply: Some(reply),  // 将发送端传递给处理者
        // ...
    };

    tx.send(signal).await?;

    // 等待接收端
    let reply = match self.reply_timeout.into() {
        Some(timeout) => tokio::time::timeout(timeout, rx).await??,
        None => rx.await?,
    };
    // ...
}
```

**设计特点**：
- 使用 `tokio::sync::oneshot` 实现一次性请求-响应
- 双层超时：邮箱容量超时 + 回复等待超时
- 调用者通过 `.await` 挂起，但不会阻塞线程

#### Tell 模式（Fire-and-Forget）

```rust
// 发送消息，不关心回复
actor_b.tell(ToolRequest { param: "data" }).await?;
```

**适用场景**：
- 日志记录
- 事件通知
- 触发后台任务

**风险**：如果处理返回 Err，会被视为 Actor Panic！

#### Forward 模式（消息转发）

```rust
impl Message<RouteMessage> for RouterActor {
    type Reply = ForwardedReply<ProcessData, String>;

    async fn handle(&mut self, msg: RouteMessage, ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        if let Some(target_ref) = self.routes.get(&msg.target_id) {
            // 将消息转发给目标 Actor，回复直接返回给原始调用者
            ctx.forward(target_ref, ProcessData(msg.data)).await
        } else {
            ForwardedReply::from_err(RouterError::TargetNotFound)
        }
    }
}
```

**设计意义**：
- 中间 Actor 可以路由消息而不成为瓶颈
- 回复直接返回给原始调用者，减少延迟
- 支持透明代理模式

#### DelegatedReply（委托回复）

```rust
impl Message<LongRunningTask> for WorkerActor {
    type Reply = DelegatedReply<TaskResult>;

    async fn handle(&mut self, msg: LongRunningTask, ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        let (delegated, reply_sender) = ctx.reply_sender();

        // 在后台任务中稍后发送回复
        tokio::spawn(async move {
            let result = process_in_background(msg).await;
            if let Some(tx) = reply_sender {
                tx.send(result);  // 稍后发送回复
            }
        });

        delegated  // 标记为委托回复
    }
}
```

**关键价值**：
- 允许 Actor 立即返回，后台异步完成工作
- 适用于长时间运行的工具调用
- 避免占用 Actor 的处理能力

---

### 2. 阻塞式 vs 异步式 Tool Call

#### 阻塞式 Tool Call

**语义**：调用者暂停当前执行流，等待工具完成

```rust
// Kameo 中的阻塞调用
let result = actor.ask(ToolCall { ... }).blocking_send()?;
```

**特点**：
- 简单直观，代码线性
- 占用调用 Actor 的处理线程
- 如果工具执行时间长，调用者无法处理其他消息

**Kameo 实现**（`src/request/ask.rs:408`）：

```rust
pub fn blocking_send(self) -> Result<<A::Reply as Reply>::Ok, SendError<...>> {
    let (reply, rx) = oneshot::channel();
    // ...
    tx.blocking_send(signal)?;  // 阻塞发送

    match rx.blocking_recv()? {  // 阻塞接收
        Ok(val) => Ok(...),
        Err(err) => Err(...),
    }
}
```

#### 异步式 Tool Call

**语义**：调用者继续执行，通过 Future/Promise 获取结果

```rust
// 方式1: 直接 await（挂起协程，不阻塞线程）
let result = actor.ask(ToolCall { ... }).await?;

// 方式2: 延迟等待（PendingReply）
let pending = actor.ask(ToolCall { ... }).enqueue().await?;
// ... 做其他工作 ...
let result = pending.await?;
```

**特点**：
- 调用者可以并行发起多个工具调用
- 通过 `.await` 挂起协程，不阻塞线程
- 需要处理并发和结果合并

---

### 3. 两个 Agent 作为 Actor 的设计

#### 场景1: A 调用 B 的工具（单向）

```rust
// Agent A
impl Message<UserQuery> for AgentA {
    type Reply = String;

    async fn handle(&mut self, msg: UserQuery, _ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        // 决定：阻塞等待还是异步并行？

        // 阻塞式：简单，但 A 无法处理其他消息
        let tool_result = self.agent_b.ask(ToolCall::Search {
            query: msg.text.clone()
        }).await.unwrap_or_default();

        format!("基于搜索结果: {}", tool_result)
    }
}
```

#### 场景2: A 并行调用多个 B 的工具

```rust
impl Message<UserQuery> for AgentA {
    type Reply = String;

    async fn handle(&mut self, msg: UserQuery, _ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        // 异步并行调用多个工具
        let search_future = self.agent_b.ask(ToolCall::Search { query: msg.text.clone() });
        let calc_future = self.agent_b.ask(ToolCall::Calculate { expression: msg.text.clone() });

        let (search_result, calc_result) = tokio::join!(search_future, calc_future);

        format!("搜索: {:?}, 计算: {:?}", search_result, calc_result)
    }
}
```

#### 场景3: A 调用 B，B 需要回调 A（双向）

**风险**：如果 A 和 B 都使用 `ask` 等待对方，会产生死锁！

```rust
// 危险：死锁！
// A 处理消息时调用 B.ask()
// B 处理该消息时又调用 A.ask()
// A 正在等待 B 回复，无法处理 B 的请求
```

**解决方案1: 使用 DelegatedReply**

```rust
// Agent A
impl Message<CallbackRequest> for AgentA {
    type Reply = DelegatedReply<String>;

    async fn handle(&mut self, msg: CallbackRequest, ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        let (delegated, reply_sender) = ctx.reply_sender();
        let b_ref = self.agent_b.clone();

        tokio::spawn(async move {
            // 在后台处理，不阻塞 A
            let result = b_ref.ask(ToolCall::Process {
                data: msg.data,
                callback_to: reply_sender.clone(), // 传递回复发送器
            }).await;

            if let Some(tx) = reply_sender {
                tx.send(format!("完成: {:?}", result));
            }
        });

        delegated
    }
}
```

**解决方案2: 使用 Tell + 事件驱动**

```rust
// Agent B 完成处理后，通过 Tell 通知 A
impl Message<ToolCall> for AgentB {
    type Reply = ();

    async fn handle(&mut self, msg: ToolCall, _ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        let result = process_tool(msg).await;

        // 通过 tell 通知 A，不等待回复
        msg.callback_to.tell(ToolCompleted {
            request_id: msg.id,
            result
        }).await.ok();
    }
}
```

#### 场景4: 长时间运行的 Tool Call

```rust
impl Message<LongRunningTool> for AgentB {
    type Reply = DelegatedReply<ToolResult>;

    async fn handle(&mut self, msg: LongRunningTool, ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        let (delegated, reply_sender) = ctx.reply_sender();

        // 将任务提交到线程池，不阻塞 Actor
        let handle = tokio::task::spawn_blocking(move || {
            heavy_computation(msg)
        });

        tokio::spawn(async move {
            match handle.await {
                Ok(result) => {
                    if let Some(tx) = reply_sender {
                        tx.send(ToolResult::Success(result));
                    }
                }
                Err(_) => { /* 处理错误 */ }
            }
        });

        delegated
    }
}
```

---

## 比较矩阵

| 模式 | 复杂度 | 适用场景 | 风险 |
|------|--------|----------|------|
| Ask + await | 低 | 简单顺序调用 | 调用者阻塞 |
| Ask + PendingReply | 中 | 延迟获取结果 | 可能死锁 |
| Tell | 低 | 事件通知 | 无反馈 |
| Forward | 中 | 消息路由 | 中间 Actor 无感知 |
| DelegatedReply | 高 | 长时间任务 | 忘记发送回复导致永久等待 |

---

## 最佳实践

### 1. 选择合适的模式

```
工具执行时间 < 10ms     → Ask + await
工具执行时间 10ms-1s    → Ask + timeout
工具执行时间 > 1s       → DelegatedReply + 后台任务
无需结果反馈            → Tell
需要透明代理            → Forward
```

### 2. 避免死锁

```rust
// 反模式：循环 Ask
do_not_do_this! {
    A.ask(B::Request).await?;  // A 等待 B
    // B 内部又调用 A.ask(...)  // B 等待 A → 死锁！
}

// 正确：使用 Tell 或 DelegatedReply
A.ask(B::Request).await?;  // A 等待 B
// B 内部使用 tell 通知 A    // 不等待，安全
```

### 3. 超时设计

```rust
let result = actor
    .ask(ToolCall { ... })
    .mailbox_timeout(Duration::from_secs(5))   // 邮箱满时等待
    .reply_timeout(Duration::from_secs(30))     // 工具执行超时
    .await;
```

### 4. 错误处理

```rust
// Tool Call 返回 Result 类型
impl Message<ToolCall> for ToolActor {
    type Reply = Result<ToolOutput, ToolError>;

    async fn handle(&mut self, msg: ToolCall, _ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        match execute_tool(msg).await {
            Ok(output) => Ok(output),
            Err(e) => {
                // 记录错误
                Err(ToolError::ExecutionFailed(e.to_string()))
            }
        }
    }
}

// 调用者处理错误
match actor.ask(ToolCall { ... }).await {
    Ok(output) => process_output(output),
    Err(SendError::HandlerError(tool_err)) => handle_tool_error(tool_err),
    Err(SendError::Timeout) => handle_timeout(),
    Err(_) => handle_other_errors(),
}
```

---

## 代码示例

### 完整的多 Agent Tool Call 系统

```rust
use kameo::prelude::*;
use std::collections::HashMap;

// ===== 消息定义 =====

#[derive(Clone)]
struct ToolRequest {
    tool_name: String,
    params: serde_json::Value,
    request_id: u64,
}

struct ToolResponse {
    request_id: u64,
    result: Result<serde_json::Value, ToolError>,
}

#[derive(Debug)]
enum ToolError {
    ToolNotFound,
    ExecutionFailed(String),
    Timeout,
}

// ===== Agent B: 工具提供者 =====

#[derive(Actor)]
struct ToolAgent {
    tools: HashMap<String, Box<dyn Tool>>,
}

impl Message<ToolRequest> for ToolAgent {
    type Reply = DelegatedReply<ToolResponse>;

    async fn handle(&mut self, msg: ToolRequest, ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        let (delegated, reply_sender) = ctx.reply_sender();

        let tool = self.tools.get(&msg.tool_name).cloned();

        tokio::spawn(async move {
            let result = if let Some(tool) = tool {
                // 在后台执行工具
                match tokio::time::timeout(
                    Duration::from_secs(30),
                    tool.execute(msg.params)
                ).await {
                    Ok(Ok(output)) => Ok(output),
                    Ok(Err(e)) => Err(ToolError::ExecutionFailed(e)),
                    Err(_) => Err(ToolError::Timeout),
                }
            } else {
                Err(ToolError::ToolNotFound)
            };

            if let Some(tx) = reply_sender {
                tx.send(ToolResponse {
                    request_id: msg.request_id,
                    result,
                });
            }
        });

        delegated
    }
}

// ===== Agent A: 工具调用者 =====

#[derive(Actor)]
struct MainAgent {
    tool_agent: ActorRef<ToolAgent>,
    pending_requests: HashMap<u64, oneshot::Sender<ToolResponse>>,
    next_request_id: u64,
}

impl Message<UserQuery> for MainAgent {
    type Reply = String;

    async fn handle(&mut self, msg: UserQuery, _ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        // 并行调用多个工具
        let tool_calls = vec![
            self.call_tool("search", json!({"query": &msg.text})).await,
            self.call_tool("calculate", json!({"expr": &msg.text})).await,
        ];

        let results = futures::future::join_all(tool_calls).await;

        format!("工具结果: {:?}", results)
    }
}

impl MainAgent {
    async fn call_tool(&mut self, name: &str, params: serde_json::Value) -> Result<serde_json::Value, ToolError> {
        let request_id = self.next_request_id;
        self.next_request_id += 1;

        let (tx, rx) = oneshot::channel();
        self.pending_requests.insert(request_id, tx);

        // 发送工具请求（使用 tell，因为回复会通过回调）
        self.tool_agent
            .tell(ToolRequest {
                tool_name: name.to_string(),
                params,
                request_id,
            })
            .await
            .map_err(|_| ToolError::ExecutionFailed("Send failed".to_string()))?;

        // 等待回调
        match tokio::time::timeout(Duration::from_secs(35), rx).await {
            Ok(Ok(response)) => response.result,
            Ok(Err(_)) => Err(ToolError::ExecutionFailed("Channel closed".to_string())),
            Err(_) => Err(ToolError::Timeout),
        }
    }
}

// 处理 ToolResponse 回调
impl Message<ToolResponse> for MainAgent {
    type Reply = ();

    async fn handle(&mut self, msg: ToolResponse, _ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        if let Some(tx) = self.pending_requests.remove(&msg.request_id) {
            let _ = tx.send(msg);
        }
    }
}
```

---

## 关键要点

1. **Ask 模式 ≈ 阻塞式 Tool Call**：语义上等价，但实现上是协程挂起而非线程阻塞

2. **DelegatedReply 是解耦关键**：允许 Actor 启动后台任务而不阻塞消息处理

3. **死锁预防**：避免循环 Ask，使用 Tell + 事件驱动或 DelegatedReply

4. **超时是必需的**：邮箱超时 + 回复超时双层保护

5. **Forward 模式优化代理场景**：中间 Actor 不成为性能瓶颈

---

## 相关文档

- Kameo Request 同步等待模式 - 基础模式分析
- [异步流式一等公民](../streaming/async-streaming-first-class.md) - 流式处理对比

---

## 参考

- [Kameo 源码](https://github.com/tqwewe/kameo) - `src/request/ask.rs`, `src/reply.rs`
- [Erlang/OTP gen_server](https://www.erlang.org/doc/design_principles/gen_server_concepts.html) - Actor 请求-响应模式起源

---

*创建时间：2026-03-10*
*更新时间：2026-03-10*
