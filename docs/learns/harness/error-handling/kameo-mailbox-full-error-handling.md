---
tags: kameo, actor, mailbox, error-handling, backpressure, dead-letter-queue, timeout
---

# Kameo Mailbox 满/超时错误处理与回传机制

> **范围**：分析 Mailbox 满或超时场景下的错误处理策略，探讨如何将错误回传给原始发送者
>
> **综合自**：kameo
>
> **优先级**：P1

---

## 概述

在使用 Kameo Actor 框架时，一个常见问题是：**当目标 Actor 的 Mailbox 已满或超时时，如何将错误信息回传给原始消息发送者？**

这个问题的核心在于理解 Kameo 的消息处理流程：
1. **发送阶段**：消息尝试进入目标 Mailbox
2. **处理阶段**：消息从 Mailbox 取出并由 Actor 处理

**关键事实**：Mailbox 满/超时发生在**发送阶段**，此时消息尚未到达目标 Actor，因此无法在目标 Actor 的 `on_message` Hook 中处理此错误。

本文分析多种解决方案：从发送端错误处理到代理模式、死信队列等高级模式。

---

## 问题分析

### 消息生命周期回顾

```
发送者 Actor                      目标 Actor
    |                                 |
    | 1. 创建 AskRequest              |
    |-------------------------------->|
    |                                 |
    | 2. 尝试发送 (send_timeout)      |
    |    - 检查 Mailbox 容量          |
    |    - 如果满 → 返回错误          |
    |-------------------------------->|
    |                                 |
    | 3. 消息入队 (Signal)            |
    |-------------------------------->| 4. 从 Mailbox 取出
    |                                 |    调用 on_message
    |                                 |
    | 5. 等待回复                     | 6. 处理消息
    |                                 |    通过 reply sender 返回
    |<--------------------------------|
```

**关键观察**：
- **步骤 2** 发生 Mailbox 满错误，消息**未进入**目标 Actor
- `on_message` Hook 只在**步骤 4-6** 被调用
- 因此，`on_message` **无法捕获** Mailbox 满错误

### Signal 结构分析

```rust
pub enum Signal<A: Actor> {
    Message {
        message: BoxMessage<A>,        // 消息内容
        actor_ref: ActorRef<A>,        // 发送者引用（保持存活）
        reply: Option<BoxReplySender>, // 回复发送器
        sent_within_actor: bool,
        message_name: &'static str,
        #[cfg(feature = "tracing")]
        caller_span: tracing::Span,
    },
    // ...
}
```

**注意**：`actor_ref` 是**目标 Actor**的引用（为了保持目标 Actor 存活），不是发送者的引用。Kameo 没有内置存储发送者 ActorRef 的机制。

---

## 解决方案

### 方案 1：发送端错误处理（推荐）

最直接的方式是在发送端处理错误，这是 Kameo 的标准做法：

```rust
impl Message<ProcessRequest> for WorkerActor {
    type Reply = ProcessResult;

    async fn handle(&mut self, msg: ProcessRequest, ctx: &mut Context<Self, Self::Reply>) -> Self::Reply {
        // 尝试发送给下游 Actor
        match self.downstream.ask(DownstreamTask { data: msg.data })
            .mailbox_timeout(Duration::from_secs(5))
            .reply_timeout(Duration::from_secs(30))
            .await
        {
            Ok(result) => ProcessResult::Success(result),
            Err(SendError::MailboxFull(_)) => {
                // 下游 Mailbox 满
                tracing::warn!("下游服务繁忙");
                ProcessResult::Busy
            }
            Err(SendError::Timeout(_)) => {
                // 处理超时
                tracing::warn!("下游处理超时");
                ProcessResult::Timeout
            }
            Err(e) => {
                tracing::error!("发送失败: {:?}", e);
                ProcessResult::Error(e.to_string())
            }
        }
    }
}
```

**优点**：
- 简单直观，符合 Rust 错误处理哲学
- 调用者知道发生了什么，可以决定重试或回退

**缺点**：
- 每个调用点都需要处理错误
- 无法自动通知"原始发送者"（如果有多层调用链）

---

### 方案 2：代理 Actor 模式（中间层处理）

创建一个代理 Actor，统一处理发送失败并通知相关方：

```rust
/// 带错误通知的请求
struct ProxiedRequest<M> {
    msg: M,
    notify_on_failure: Option<ActorRef<NotificationActor>>,
    request_id: Uuid,
}

/// 代理 Actor，负责转发消息并处理失败
#[derive(Actor)]
struct ProxyActor<A: Actor> {
    target: ActorRef<A>,
    dlq: ActorRef<DeadLetterQueue>,
}

impl<M> Message<ProxiedRequest<M>> for ProxyActor<TargetActor>
where
    M: Send + 'static,
    TargetActor: Message<M>,
{
    type Reply = Result<<TargetActor::Reply as Reply>::Ok, ProxyError>;

    async fn handle(
        &mut self,
        msg: ProxiedRequest<M>,
        _ctx: &mut Context<Self, Self::Reply>,
    ) -> Self::Reply {
        match self.target
            .ask(msg.msg)
            .mailbox_timeout(Duration::from_secs(5))
            .await
        {
            Ok(result) => Ok(result),
            Err(e) => {
                // 通知监听者
                if let Some(notifier) = msg.notify_on_failure {
                    let _ = notifier.tell(RequestFailed {
                        request_id: msg.request_id,
                        error: format!("{:?}", e),
                        timestamp: Instant::now(),
                    }).await;
                }

                // 发送到死信队列
                let _ = self.dlq.tell(DeadLetter {
                    original_msg: Box::new(msg.msg),
                    error: e,
                    retry_count: 0,
                }).await;

                Err(ProxyError::ForwardedToDLQ)
            }
        }
    }
}

/// 使用示例
let proxy = ProxyActor::spawn(ProxyActor {
    target: worker_ref.clone(),
    dlq: dlq_ref.clone(),
});

let result = proxy.ask(ProxiedRequest {
    msg: MyTask { data: vec![1, 2, 3] },
    notify_on_failure: Some(notification_ref),
    request_id: Uuid::new_v4(),
}).await;
```

**优点**：
- 集中处理错误逻辑
- 可以集成重试、死信队列、通知机制

**缺点**：
- 增加一层跳转，延迟增加
- 需要维护代理 Actor 状态

---

### 方案 3：死信队列（DLQ）模式

将处理失败的消息发送到专门的死信队列 Actor：

```rust
/// 死信队列 Actor
#[derive(Actor)]
struct DeadLetterQueue {
    failed_messages: Vec<DeadLetter>,
    subscribers: Vec<ActorRef<FailureNotification>>,
}

struct DeadLetter {
    original_sender: Option<ActorId>,  // 尝试存储发送者 ID
    message_name: String,
    error: String,
    timestamp: Instant,
    payload: Vec<u8>, // 序列化的消息
}

impl Message<DeadLetter> for DeadLetterQueue {
    type Reply = ();

    async fn handle(&mut self, msg: DeadLetter, _ctx: &mut Context<Self, Self::Reply>) {
        tracing::error!("消息进入死信队列: {}", msg.message_name);

        // 通知所有订阅者
        for subscriber in &self.subscribers {
            let _ = subscriber.tell(FailureNotification {
                actor_id: msg.original_sender,
                message_name: msg.message_name.clone(),
                error: msg.error.clone(),
            }).await;
        }

        self.failed_messages.push(msg);

        // 持久化到存储（可选）
        if self.failed_messages.len() > 1000 {
            self.persist_to_storage().await;
        }
    }
}

/// 使用 DLQ 的包装函数
async fn send_with_dlq<A, M>(
    target: &ActorRef<A>,
    msg: M,
    dlq: &ActorRef<DeadLetterQueue>,
) -> Result<<A::Reply as Reply>::Ok, ()>
where
    A: Actor + Message<M>,
    M: Send + 'static + Serialize,
{
    match target.ask(msg).mailbox_timeout(Duration::from_secs(5)).await {
        Ok(result) => Ok(result),
        Err(e) => {
            let letter = DeadLetter {
                original_sender: None, // Kameo 不直接提供获取发送者的方法
                message_name: std::any::type_name::<M>().to_string(),
                error: format!("{:?}", e),
                timestamp: Instant::now(),
                payload: serde_json::to_vec(&msg).unwrap_or_default(),
            };
            let _ = dlq.tell(letter).await;
            Err(())
        }
    }
}
```

**注意**：Kameo 不直接提供"获取当前 Actor ID"的 API，所以 `original_sender` 需要手动传递。

---

### 方案 4：消息上下文模式（手动传递发送者）

在消息中显式包含发送者引用和回调信息：

```rust
/// 带回调上下文的请求
struct ContextualRequest<M, R> {
    payload: M,
    respond_to: ActorRef<ResponseHandler<R>>,
    request_id: Uuid,
}

/// 响应处理器
#[derive(Actor)]
struct ResponseHandler<R> {
    pending: HashMap<Uuid, oneshot::Sender<Result<R, RequestError>>>,
}

impl<R: Reply> Message<RequestCompleted<R>> for ResponseHandler<R> {
    type Reply = ();

    async fn handle(&mut self, msg: RequestCompleted<R>, _ctx: &mut Context<Self, Self::Reply>) {
        if let Some(tx) = self.pending.remove(&msg.request_id) {
            let _ = tx.send(msg.result);
        }
    }
}

/// 处理带上下文的请求
impl<M, R> Message<ContextualRequest<M, R>> for WorkerActor
where
    M: Send + 'static,
    R: Reply,
{
    type Reply = ();

    async fn handle(
        &mut self,
        msg: ContextualRequest<M, R>,
        _ctx: &mut Context<Self, Self::Reply>,
    ) {
        // 尝试转发给实际处理者
        match self.processor.ask(msg.payload).await {
            Ok(result) => {
                let _ = msg.respond_to.tell(RequestCompleted {
                    request_id: msg.request_id,
                    result: Ok(result),
                }).await;
            }
            Err(e) => {
                // 显式通知发送者失败
                let _ = msg.respond_to.tell(RequestCompleted {
                    request_id: msg.request_id,
                    result: Err(RequestError::MailboxFull),
                }).await;
            }
        }
    }
}

/// 发送端使用
let (tx, rx) = oneshot::channel();
let request_id = Uuid::new_v4();

// 注册待处理请求
response_handler.tell(RegisterPending {
    request_id,
    sender: tx,
}).await.ok();

// 发送带上下文的请求
worker.tell(ContextualRequest {
    payload: MyTask { data: vec![1, 2, 3] },
    respond_to: response_handler_ref,
    request_id,
}).await.ok();

// 等待结果（包括失败通知）
match timeout(Duration::from_secs(10), rx).await {
    Ok(Ok(result)) => println!("成功: {:?}", result),
    Ok(Err(e)) => println!("处理失败: {:?}", e),
    Err(_) => println!("等待超时"),
}
```

**优点**：
- 显式控制回调路径
- 可以处理任意层级的嵌套调用

**缺点**：
- 代码复杂度增加
- 需要手动管理 request_id 和 pending 状态

---

### 方案 5：Future 组合器模式（推荐用于复杂场景）

使用 Rust Future 组合器优雅处理超时和错误：

```rust
use futures::{future::BoxFuture, FutureExt};

/// 带超时和重试的请求
async fn send_with_retry<A, M>(
    target: &ActorRef<A>,
    msg: M,
    max_retries: u32,
    base_delay: Duration,
) -> Result<<A::Reply as Reply>::Ok, SendError<M, <A::Reply as Reply>::Error>>
where
    A: Actor + Message<M>,
    M: Clone + Send + 'static,
{
    let mut attempts = 0;
    let mut delay = base_delay;

    loop {
        match target.ask(msg.clone())
            .mailbox_timeout(Duration::from_secs(5))
            .reply_timeout(Duration::from_secs(30))
            .await
        {
            Ok(result) => return Ok(result),
            Err(SendError::MailboxFull(_)) if attempts < max_retries => {
                attempts += 1;
                tracing::warn!("Mailbox 满，第 {} 次重试", attempts);
                tokio::time::sleep(delay).await;
                delay *= 2; // 指数退避
            }
            Err(e) => return Err(e),
        }
    }
}

/// 使用示例
match send_with_retry(&worker, task, 3, Duration::from_millis(100)).await {
    Ok(result) => println!("成功: {:?}", result),
    Err(SendError::MailboxFull(_)) => {
        // 重试后仍失败，通知调用者
        notification_actor.tell(WorkerOverloaded).await.ok();
    }
    Err(e) => println!("其他错误: {:?}", e),
}
```

---

## 关键设计决策

### 为什么 Kameo 不提供"自动回传 Mailbox 满错误"？

1. **错误发生的位置**：Mailbox 满错误发生在**发送端**，目标 Actor 甚至不知道有人尝试给它发消息
2. **调用栈分离**：Actor 模型是异步、去耦的，发送者不会阻塞等待"接收确认"
3. **背压策略多样性**：不同的应用需要不同的背压策略（重试、丢弃、降级、死信队列等）

### 如何在消息中获取发送者身份？

Kameo 不提供自动获取发送者 ActorRef 的 API，需要**显式传递**：

```rust
struct MyMessage {
    data: Vec<u8>,
    sender: ActorRef<SenderActor>, // 手动包含
    request_id: Uuid,
}

// 发送时
target.tell(MyMessage {
    data: vec![1, 2, 3],
    sender: my_ref.clone(), // 传递自己的引用
    request_id: Uuid::new_v4(),
}).await;
```

**注意**：`ActorRef::clone()` 是廉价的（只是 Arc 克隆）。

---

## 最佳实践建议

### 1. 选择合适的策略

| 场景 | 推荐方案 |
|------|----------|
| 简单调用链 | 方案 1：发送端错误处理 |
| 多层服务调用 | 方案 2：代理 Actor 模式 |
| 不能丢失消息 | 方案 3：死信队列 |
| 需要异步回调 | 方案 4：消息上下文模式 |
| 临时过载 | 方案 5：Future 组合器（重试+退避）|

### 2. 超时配置建议

```rust
// 快速查询（状态检查）
.actor_ref.ask(QueryStatus)
    .mailbox_timeout(Duration::from_millis(100))
    .reply_timeout(Duration::from_secs(1))

// 普通处理
.actor_ref.ask(ProcessTask)
    .mailbox_timeout(Duration::from_secs(2))
    .reply_timeout(Duration::from_secs(10))

// 长时间任务
.actor_ref.ask(HeavyComputation)
    .mailbox_timeout(Duration::from_secs(5))
    .reply_timeout(Duration::from_secs(300))
```

### 3. 监控与告警

```rust
// 记录 Mailbox 满的频率
if let Err(SendError::MailboxFull(_)) = result {
    metrics::counter!("actor_mailbox_full_total", 1,
        "target_actor" => target_actor_name
    );
}
```

### 4. 避免级联故障

```rust
// 错误：连续调用多个 Actor，任一失败都可能导致整体失败
let a_result = actor_a.ask(msg_a).await?;  // 可能失败
let b_result = actor_b.ask(msg_b).await?;  // 可能失败
let c_result = actor_c.ask(msg_c).await?;  // 可能失败

// 正确：使用 try_join 并行处理，或使用优雅降级
let (a_result, b_result, c_result) = tokio::join!(
    actor_a.ask(msg_a),
    actor_b.ask(msg_b),
    actor_c.ask(msg_c),
);

// 处理部分失败
let result = MyResult {
    a: a_result.unwrap_or_default(),
    b: b_result.unwrap_or_default(),
    c: c_result.unwrap_or_default(),
};
```

---

## 总结

| 方案 | 复杂度 | 适用场景 | 是否能"自动"通知 |
|------|--------|----------|-----------------|
| 发送端错误处理 | 低 | 简单场景 | 否（显式处理） |
| 代理 Actor | 中 | 服务网格 | 是（通过 notify_on_failure） |
| 死信队列 | 中 | 不能丢消息 | 是（通过订阅） |
| 消息上下文 | 高 | 复杂回调 | 是（显式 respond_to） |
| Future 组合器 | 低 | 临时过载 | 否（但自动重试） |

**核心原则**：在 Actor 模型中，错误处理应该在**发送端**显式进行，而不是期望框架自动回传。这是异步消息传递的基本特性。

---

## 相关文档

- [Kameo Request 与 Mailbox 设计](../architecture/kameo-request-mailbox-design.md) - Request 模型详解
- [Kameo Request 与 Tool Call 对比](../concurrency/kameo-request-toolcall-pattern.md) - Tool Call 模式对比
- [错误恢复与上下文无损](./error-recovery-without-context-loss.md) - 错误恢复模式

---

*创建时间：2026-03-10*
*更新时间：2026-03-10*
