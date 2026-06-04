---
tags: kameo, actor, request-pattern, mailbox, timeout, hooks, architecture
---

# Kameo Request 模型与 Mailbox 设计

> **范围**：深入分析 Kameo Actor 框架的请求模型、双层超时机制、Mailbox 消息处理流程及可扩展的 Hooks 设计
>
> **综合自**：kameo
>
> **优先级**：P1

---

## 概述

Kameo 是一个 Rust Actor 框架，其 Request 模型设计体现了 Actor 模型的核心思想：**通过消息传递实现松耦合，通过邮箱队列实现异步处理**。理解其设计要点对于构建高并发、容错性强的 Agent 系统至关重要。

本文深入剖析：
1. Request 的完整生命周期（创建 → 入队 → 处理 → 回复）
2. 双层超时保护机制
3. Mailbox 的消息流转与 Hooks 扩展点
4. 实际应用中的设计模式

---

## Request 模型设计要点

### 1. 核心数据结构

Request 在 Kameo 中由 `AskRequest` 结构体表示（`src/request/ask.rs`）：

```rust
pub struct AskRequest<'a, A, M, Tm, Tr>
where
    A: Actor + Message<M>,
    M: Send + 'static,
{
    actor_ref: &'a ActorRef<A>,  // 目标 Actor 引用
    msg: M,                       // 消息体
    mailbox_timeout: Tm,         // 邮箱容量等待超时（类型级标记）
    reply_timeout: Tr,           // 回复等待超时（类型级标记）
    message_name: &'static str,  // 消息类型名（调试/追踪用）
    #[cfg(all(debug_assertions, feature = "tracing"))]
    called_at: &'static std::panic::Location<'static>, // 调用位置（死锁检测）
}
```

**设计亮点**：
- **类型状态模式**：`Tm` 和 `Tr` 使用 `WithoutRequestTimeout` / `WithRequestTimeout` 作为类型标记，在编译期确保超时配置的类型安全
- **零成本抽象**：未设置超时时，类型为 `WithoutRequestTimeout`（空结构体），无运行时开销

### 2. 请求生命周期

```
调用者                        目标 Actor
   |                              |
   |  1. 创建 AskRequest          |
   |----------------------------->|
   |                              |
   |  2. 检查邮箱容量             |
   |  (mailbox_timeout)           |
   |----------------------------->|
   |                              |
   |  3. 消息入队 (Signal)        |
   |----------------------------->|  4. 从 Mailbox 取出
   |                              |     调用 on_message
   |                              |
   |  5. 等待回复                 |  6. 处理消息
   |  (reply_timeout)             |     调用 handler
   |<-----------------------------|
   |                              |
   |  7. 返回结果                 |
   |<-----------------------------|
```

**关键代码**（`src/request/ask.rs:110-154`）：

```rust
pub async fn send(self) -> Result<<A::Reply as Reply>::Ok, SendError<...>> {
    // 1. 创建一次性通道用于接收回复
    let (reply, rx) = oneshot::channel();

    // 2. 包装为 Signal
    let signal = Signal::Message {
        message: Box::new(self.msg),
        actor_ref: self.actor_ref.clone(),
        reply: Some(reply),
        sent_within_actor: self.actor_ref.is_current(),
        message_name: self.message_name,
        #[cfg(feature = "tracing")]
        caller_span: tracing::Span::current(),
    };

    let tx = self.actor_ref.mailbox_sender();

    // 3. 发送消息（带邮箱容量超时）
    match self.mailbox_timeout.into() {
        Some(timeout) => {
            tx.send_timeout(signal, timeout).await?;  // 超时返回 Err
        }
        None => {
            tx.send(signal).await?;  // 无限等待容量
        }
    }

    // 4. 等待回复（带处理超时）
    let reply = match self.reply_timeout.into() {
        Some(timeout) => tokio::time::timeout(timeout, rx).await??,
        None => rx.await?,
    };

    // 5. 类型转换并返回
    match reply {
        Ok(val) => Ok(<A::Reply as Reply>::downcast_ok(val)),
        Err(err) => Err(<A::Reply as Reply>::downcast_err(err)),
    }
}
```

### 3. 阻塞语义澄清

**重要**：Kameo 的 "阻塞" 是**协程级**而非**线程级**：

| 概念 | 说明 |
|------|------|
| `.await` | 挂起当前协程，让出线程给其他任务 |
| `blocking_send()` | 阻塞当前线程（用于同步上下文） |
| Actor 处理 | 单线程顺序处理消息，一次只处理一个 |

当调用 `actor.ask(msg).await` 时：
1. 调用者协程挂起，等待 `oneshot::Receiver` 收到回复
2. 线程可继续执行其他任务
3. 目标 Actor 按顺序从 Mailbox 取出消息处理
4. 处理完成后通过 `oneshot::Sender` 发送回复
5. 调用者协程恢复，返回结果

---

## 双层超时机制

Kameo 提供了精细的超时控制，分为两个阶段：

### 1. Mailbox Timeout（邮箱容量超时）

**解决的问题**：目标 Actor 邮箱已满，消息无法入队

```rust
let result = actor
    .ask(msg)
    .mailbox_timeout(Duration::from_secs(5))  // 最多等待 5 秒入队
    .await;
```

**错误类型**：
```rust
pub enum SendError<M, E> {
    ActorNotRunning(M),  // Actor 未运行
    ActorStopped,        // Actor 已停止
    MailboxFull(M),      // 邮箱满（超时后）
    HandlerError(E),     // 处理出错
    Timeout(Option<M>),  // 其他超时
}
```

**底层实现**（`src/mailbox.rs:198-212`）：

```rust
pub async fn send_timeout(
    &self,
    signal: Signal<A>,
    timeout: Duration,
) -> Result<(), mpsc::error::SendTimeoutError<Signal<A>>> {
    match &self.inner {
        MailboxSenderInner::Bounded(tx) => tx.send_timeout(signal, timeout).await,
        MailboxSenderInner::Unbounded(tx) => {
            // 无界邮箱直接发送，永不超时
            tx.send(signal)
                .map_err(|err| mpsc::error::SendTimeoutError::Closed(err.0))
        }
    }
}
```

### 2. Reply Timeout（回复等待超时）

**解决的问题**：消息已入队，但处理时间过长

```rust
let result = actor
    .ask(msg)
    .reply_timeout(Duration::from_secs(30))  // 最多等待 30 秒回复
    .await;
```

**底层实现**（`src/request/ask.rs:146-148`）：

```rust
let reply = match self.reply_timeout.into() {
    Some(timeout) => tokio::time::timeout(timeout, rx).await??,
    None => rx.await?,
};
```

**注意**：`tokio::time::timeout` 包装 `rx.await`，超时返回 `Elapsed` 错误

### 3. 组合使用

```rust
let result = actor
    .ask(ComputeRequest { data })
    .mailbox_timeout(Duration::from_secs(5))   // 5秒入队
    .reply_timeout(Duration::from_secs(60))    // 60秒处理
    .await;

match result {
    Ok(output) => println!("结果: {}", output),
    Err(SendError::MailboxFull(_)) => println!("系统繁忙，请稍后重试"),
    Err(SendError::Timeout(_)) => println!("处理超时"),
    Err(e) => println!("错误: {:?}", e),
}
```

---

## Mailbox 消息处理与 Hooks

### 1. Mailbox 结构

Mailbox 本质上是 Tokio MPSC 通道的包装（`src/mailbox.rs`）：

```rust
pub struct MailboxSender<A: Actor> {
    inner: MailboxSenderInner<A>,
    // 指标统计...
}

enum MailboxSenderInner<A: Actor> {
    Bounded(mpsc::Sender<Signal<A>>),      // 有界邮箱（背压）
    Unbounded(mpsc::UnboundedSender<Signal<A>>),  // 无界邮箱
}

pub struct MailboxReceiver<A: Actor> {
    inner: MailboxReceiverInner<A>,
}
```

### 2. Signal 类型

Mailbox 中传递的不是原始消息，而是 `Signal` 枚举（`src/mailbox.rs`）：

```rust
pub(crate) enum Signal<A: Actor> {
    /// 用户消息
    Message {
        message: BoxMessage<A>,        // 装箱的消息
        actor_ref: ActorRef<A>,        // 发送者引用
        reply: Option<BoxReplySender>, // 回复通道（可选）
        sent_within_actor: bool,       // 是否 Actor 自发送
        message_name: &'static str,    // 消息名
        #[cfg(feature = "tracing")]
        caller_span: tracing::Span,    // 追踪 span
    },
    /// Actor 启动完成
    StartupFinished,
    /// 停止 Actor
    Stop,
    /// 监督重启
    SupervisorRestart,
    /// 链接 Actor 死亡
    LinkDied {
        id: ActorId,
        reason: ActorStopReason,
    },
}
```

### 3. 消息处理 Hooks

Kameo 在 Actor trait 中提供了**消息拦截 Hook**：

```rust
pub trait Actor: Sized + Send + 'static {
    // ...

    /// 默认直接处理消息，可覆盖实现自定义逻辑
    fn on_message(
        &mut self,
        msg: BoxMessage<Self>,           // 消息
        actor_ref: ActorRef<Self>,       // Actor 引用
        tx: Option<BoxReplySender>,      // 回复发送器
        stop: &mut bool,                 // 停止标志
    ) -> impl Future<Output = Result<(), Box<dyn ReplyError>>> + Send {
        async move {
            msg.handle_dyn(self, actor_ref, tx, stop).await
        }
    }
}
```

**使用场景**：
- **消息日志**：记录所有进出消息
- **消息过滤**：丢弃或修改特定消息
- **限流控制**：实现令牌桶等算法
- **指标统计**：消息处理时间统计

**示例：带日志的消息处理**

```rust
impl Actor for MyActor {
    type Args = Self;
    type Error = Infallible;

    async fn on_start(args: Self::Args, _: ActorRef<Self>) -> Result<Self, Self::Error> {
        Ok(args)
    }

    fn on_message(
        &mut self,
        msg: BoxMessage<Self>,
        actor_ref: ActorRef<Self>,
        tx: Option<BoxReplySender>,
        stop: &mut bool,
    ) -> impl Future<Output = Result<(), Box<dyn ReplyError>>> + Send {
        async move {
            let msg_name = msg.name();
            let start = Instant::now();

            tracing::info!("开始处理消息: {}", msg_name);

            let result = msg.handle_dyn(self, actor_ref, tx, stop).await;

            tracing::info!(
                "消息处理完成: {}，耗时: {:?}",
                msg_name,
                start.elapsed()
            );

            result
        }
    }
}
```

### 4. 额外的扩展点

除了 `on_message`，Kameo 还提供了其他 Hooks：

| Hook | 触发时机 | 用途 |
|------|----------|------|
| `on_start` | Actor 启动前 | 初始化资源、建立连接 |
| `on_stop` | Actor 停止前 | 清理资源、持久化状态 |
| `on_panic` | 消息处理 panic 时 | 错误恢复、决定是否重启 |
| `on_link_died` | 链接的 Actor 死亡时 | 监督策略实施 |
| `next` | 等待下一个 Signal 时 | 自定义多路复用（如同时监听多个通道）|

---

## 实际应用模式

### 1. 消息拦截与转换

```rust
struct ValidatingActor {
    schema: JsonSchema,
}

impl Actor for ValidatingActor {
    fn on_message(
        &mut self,
        msg: BoxMessage<Self>,
        actor_ref: ActorRef<Self>,
        tx: Option<BoxReplySender>,
        stop: &mut bool,
    ) -> impl Future<Output = Result<(), Box<dyn ReplyError>>> + Send {
        async move {
            // 前置验证
            if let Some(req) = msg.downcast_ref::<ApiRequest>() {
                if let Err(e) = self.schema.validate(&req.payload) {
                    // 验证失败，直接返回错误，不执行 handler
                    if let Some(tx) = tx {
                        let _ = tx.send(Err(Box::new(e)));
                    }
                    return Ok(());
                }
            }

            // 验证通过，继续处理
            msg.handle_dyn(self, actor_ref, tx, stop).await
        }
    }
}
```

### 2. 消息队列监控

```rust
struct MonitoredActor {
    message_count: AtomicU64,
    processing_times: Histogram,
}

impl Actor for MonitoredActor {
    fn on_message(
        &mut self,
        msg: BoxMessage<Self>,
        actor_ref: ActorRef<Self>,
        tx: Option<BoxReplySender>,
        stop: &mut bool,
    ) -> impl Future<Output = Result<(), Box<dyn ReplyError>>> + Send {
        async move {
            self.message_count.fetch_add(1, Ordering::Relaxed);
            let start = Instant::now();

            let result = msg.handle_dyn(self, actor_ref, tx, stop).await;

            self.processing_times.record(start.elapsed().as_millis() as f64);

            // 告警：处理时间过长
            if start.elapsed() > Duration::from_secs(10) {
                tracing::warn!("消息处理缓慢: {}", msg.name());
            }

            result
        }
    }
}
```

### 3. 死信队列（Dead Letter Queue）

```rust
struct DlqActor {
    primary: ActorRef<WorkerActor>,
    dlq: ActorRef<DeadLetterQueue>,
}

impl Actor for DlqActor {
    fn on_message(
        &mut self,
        msg: BoxMessage<Self>,
        actor_ref: ActorRef<Self>,
        tx: Option<BoxReplySender>,
        stop: &mut bool,
    ) -> impl Future<Output = Result<(), Box<dyn ReplyError>>> + Send {
        async move {
            // 尝试转发给主 Actor
            match self.primary.try_send(msg.clone()).await {
                Ok(()) => Ok(()),
                Err(SendError::MailboxFull(_)) => {
                    // 主 Actor 繁忙，转入死信队列
                    self.dlq.tell(DeadLetter {
                        original_msg: msg,
                        reason: "Mailbox full".to_string(),
                        timestamp: Instant::now(),
                    }).await.ok();

                    // 如果原消息需要回复，返回错误
                    if let Some(tx) = tx {
                        let _ = tx.send(Err(Box::new(ServiceUnavailable)));
                    }
                    Ok(())
                }
                Err(e) => Err(Box::new(e)),
            }
        }
    }
}
```

---

## 关键设计决策

### 1. 为什么使用类型状态模式管理超时？

```rust
// 未设置超时：零成本
AskRequest<A, M, WithoutRequestTimeout, WithoutRequestTimeout>

// 设置 mailbox_timeout：编译期确保类型安全
AskRequest<A, M, WithRequestTimeout, WithoutRequestTimeout>
```

**优势**：
- 避免运行时检查 `Option<Duration>`
- 方法仅在合适的类型上可用（如 `mailbox_timeout()` 只能在未设置时调用）
- 无运行时开销

### 2. 为什么用 oneshot 通道？

```rust
let (reply, rx) = oneshot::channel();  // 只能发送一次，接收一次
```

**优势**：
- 强制单次请求-响应语义
- 避免内存泄漏（通道自动关闭）
- 类型安全：无法重复发送或接收

### 3. 为什么 Mailbox 不提供消息滞留 Hook？

Kameo **不提供**消息在 Mailbox 中等待时的 Hooks，原因：

1. **性能**：Mailbox 是高频操作，Hook 会引入额外开销
2. **复杂度**：消息在等待期间尚未被 Actor "拥有"，难以定义有意义的操作
3. **替代方案**：可以通过以下方式实现类似功能：
   - **Metrics 特性**：内置的 Prometheus 指标（`kameo_messages_sent` / `kameo_messages_received`）
   - **自定义 Mailbox**：实现自己的 `MailboxSender`/`MailboxReceiver`
   - **消息入队时间戳**：在消息中携带 `created_at`，在 `on_message` 中计算等待时间

---

## 最佳实践

### 1. 超时配置建议

```rust
// CPU 密集型任务：较长处理超时
actor.ask(ComputeTask { ... })
    .mailbox_timeout(Duration::from_secs(1))
    .reply_timeout(Duration::from_secs(300))  // 5分钟
    .await;

// I/O 任务：适中超时
actor.ask(FetchData { ... })
    .mailbox_timeout(Duration::from_secs(5))
    .reply_timeout(Duration::from_secs(30))
    .await;

// 快速查询：短超时
actor.ask(GetStatus)
    .mailbox_timeout(Duration::from_millis(100))
    .reply_timeout(Duration::from_secs(1))
    .await;
```

### 2. 监控 Mailbox 积压

```rust
// 通过指标监控（需启用 metrics 特性）
// kameo_messages_sent - kameo_messages_received = 积压量

// 或使用自定义 Hook 估算
fn on_message(...) {
    async move {
        let wait_time = msg.enqueue_time().elapsed();
        if wait_time > Duration::from_secs(10) {
            tracing::warn!("消息等待时间过长: {:?}", wait_time);
        }
        // ...
    }
}
```

### 3. 避免死锁

```rust
// 错误：循环 Ask 导致死锁
impl Message<Request> for ActorA {
    async fn handle(&mut self, msg: Request, ctx: &mut Context<...>) {
        let b_response = self.actor_b.ask(RequestToB).await?;  // A 等待 B
        // 如果 B 内部又调用 A.ask(...)，则死锁！
    }
}

// 正确：使用 Tell 或 DelegatedReply
impl Message<Request> for ActorA {
    async fn handle(&mut self, msg: Request, ctx: &mut Context<...>) {
        // 方案1：Tell（不等待回复）
        self.actor_b.tell(RequestToB).await?;

        // 方案2：DelegatedReply（异步回复）
        let (delegated, tx) = ctx.reply_sender();
        tokio::spawn(async move {
            let result = self.actor_b.ask(RequestToB).await;
            if let Some(tx) = tx { tx.send(result); }
        });
        delegated
    }
}
```

---

## 与其他框架比较

| 特性 | Kameo | Erlang/OTP | Akka |
|------|-------|------------|------|
| 邮箱类型 | Bounded/Unbounded | Bounded (默认 1000) | Bounded/Unbounded |
| 超时机制 | 双层（入队+处理） | 仅处理超时 | 仅处理超时 |
| 消息拦截 | `on_message` Hook | 需自定义 Behavior | `aroundReceive` |
| 死信队列 | 需手动实现 | 内置 | 内置 |
| 背压 | 有界邮箱 + timeout | 有界邮箱阻塞 | 有界邮箱 + 多种策略 |

---

## 关键要点

1. **双层超时**：`mailbox_timeout` 解决入队问题，`reply_timeout` 解决处理问题
2. **协程非线程**：`.await` 挂起协程不阻塞线程，充分利用异步优势
3. **消息拦截**：通过 `on_message` Hook 实现日志、验证、监控等横切关注点
4. **无滞留 Hook**：Mailbox 内部不提供 Hook，通过 Metrics 或时间戳实现监控
5. **类型安全**：类型状态模式确保超时配置在编译期正确

---

## 相关文档

- [Kameo Request 与 Tool Call 对比](../concurrency/kameo-request-toolcall-pattern.md) - Tool Call 模式对比
- [状态快照并发](../concurrency/state-snapshot-concurrency.md) - Actor 并发模式

---

## 参考

- [Kameo 文档](https://docs.rs/kameo/)
- [Tokio MPSC 文档](https://docs.rs/tokio/sync/mpsc/index.html)
- [Erlang Mailboxes](https://www.erlang.org/doc/reference_manual/processes.html#message-passing)

---

*创建时间：2026-03-10*
*更新时间：2026-03-10*
