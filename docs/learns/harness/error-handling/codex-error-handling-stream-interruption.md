---
tags: error-handling, retry, streaming, resilience, codex, harness
---

# Codex 错误处理与流中断恢复机制

> **范围**：深入分析 OpenAI Codex 的错误分类、可重试错误处理、流中断恢复策略和 WebSocket 回退机制
>
> **综合自**：codex (openai/codex)
>
> **优先级**：P1

---

## 概述

Codex 实现了多层次的错误处理和恢复机制，确保在网络不稳定或服务异常时提供流畅的用户体验。核心设计目标是在保持响应性的同时，优雅地处理各种故障场景。

核心策略：
1. **错误分类**：明确区分可重试错误与不可重试错误
2. **指数退避**：智能重试策略避免频繁请求
3. **传输层回退**：WebSocket 失败时自动切换到 HTTP
4. **流中断恢复**：SSE/WebSocket 流中断后的自动重连

---

## 错误分类体系

### CodexErr 枚举

Codex 使用 `thiserror` 定义了完整的错误层次结构：

```rust
#[derive(Error, Debug)]
pub enum CodexErr {
    /// 轮次被用户中断
    #[error("turn aborted. Something went wrong? Hit `/feedback` to report the issue.")]
    TurnAborted,

    /// 流在完成前断开 - 可重试
    #[error("stream disconnected before completion: {0}")]
    Stream(String, Option<Duration>),

    /// 上下文窗口超出
    #[error("Codex ran out of room in the model's context window...")]
    ContextWindowExceeded,

    /// 服务器过载
    #[error("Selected model is at capacity. Please try a different model.")]
    ServerOverloaded,

    /// 响应流失败
    #[error("{0}")]
    ResponseStreamFailed(ResponseStreamFailed),

    /// 连接失败
    #[error("{0}")]
    ConnectionFailed(ConnectionFailedError),

    /// 内部服务器错误
    #[error("We're currently experiencing high demand...")]
    InternalServerError,

    /// 配额超限
    #[error("Quota exceeded. Check your plan and billing details.")]
    QuotaExceeded,

    /// 重试次数超限
    #[error("{0}")]
    RetryLimit(RetryLimitReachedError),

    // ... 其他错误变体
}
```

### 可重试性判断

Codex 实现了 `is_retryable()` 方法来确定错误是否值得重试：

```rust
impl CodexErr {
    pub fn is_retryable(&self) -> bool {
        match self {
            // 不可重试错误：用户取消、配置错误、权限问题等
            CodexErr::TurnAborted
            | CodexErr::Interrupted
            | CodexErr::QuotaExceeded
            | CodexErr::UsageNotIncluded
            | CodexErr::ContextWindowExceeded
            | CodexErr::InvalidRequest(_)
            | CodexErr::Sandbox(_)
            | CodexErr::RetryLimit(_) => false,

            // 可重试错误：网络问题、流中断、服务器错误等
            CodexErr::Stream(..)
            | CodexErr::Timeout
            | CodexErr::UnexpectedStatus(_)
            | CodexErr::ResponseStreamFailed(_)
            | CodexErr::ConnectionFailed(_)
            | CodexErr::InternalServerError
            | CodexErr::Io(_)
            | CodexErr::Json(_) => true,

            // ... 平台特定错误
        }
    }
}
```

**设计理由**：
- **幂等性考虑**：只有无副作用的错误才应重试
- **用户体验**：避免在配置错误或权限问题上无限重试
- **成本考虑**：配额超限和上下文窗口错误重试无效

---

## 流中断处理机制

### Stream 错误定义

当 SSE 或 WebSocket 流在完成前断开时，Codex 返回特定的 `Stream` 错误：

```rust
/// Returned by ResponsesClient when the SSE stream disconnects or errors out
/// **after** the HTTP handshake has succeeded but **before** it finished
/// emitting `response.completed`.
///
/// The Session loop treats this as a transient error and will automatically
/// retry the turn.
#[error("stream disconnected before completion: {0}")]
Stream(String, Option<Duration>),
```

### 重试循环实现

Codex 的主采样循环实现了完整的重试逻辑：

```rust
async fn sample_turn(...) -> CodexResult<...> {
    let mut retries = 0;

    loop {
        // 尝试执行轮次
        let result = execute_turn(...).await;

        match result {
            Ok(output) => return Ok(output),

            // 检查错误是否可重试
            Err(err) => {
                if !err.is_retryable() {
                    return Err(err);  // 不可重试，直接返回
                }

                let max_retries = turn_context.provider.stream_max_retries();

                // 尝试 WebSocket → HTTP 回退
                if retries >= max_retries
                    && client_session.try_switch_fallback_transport(...).await
                {
                    sess.send_event(
                        &turn_context,
                        EventMsg::Warning(WarningEvent {
                            message: format!(
                                "Falling back from WebSockets to HTTPS transport. {err:#}"
                            ),
                        }),
                    ).await;
                    retries = 0;  // 重置重试计数器
                    continue;
                }

                // 执行重试
                if retries < max_retries {
                    retries += 1;
                    let delay = match &err {
                        CodexErr::Stream(_, requested_delay) => {
                            requested_delay.unwrap_or_else(|| backoff(retries))
                        }
                        _ => backoff(retries),
                    };

                    // 向用户显示重试信息
                    sess.notify_stream_error(
                        &turn_context,
                        format!("Reconnecting... {retries}/{max_retries}"),
                        err,
                    ).await;

                    tokio::time::sleep(delay).await;
                } else {
                    return Err(err);  // 重试耗尽
                }
            }
        }
    }
}
```

### 指数退避策略

```rust
fn backoff(retries: u32) -> Duration {
    // 指数退避：2^retries 秒，最高 60 秒
    let secs = 2u64.saturating_pow(retries).min(60);
    Duration::from_secs(secs)
}
```

**退避时间表**：
- 第 1 次重试：2 秒
- 第 2 次重试：4 秒
- 第 3 次重试：8 秒
- 第 4 次重试：16 秒
- 第 5 次及以后：最多 60 秒

---

## WebSocket 回退机制

### 回退触发条件

WebSocket 回退在以下情况触发：

```rust
async fn try_switch_fallback_transport(...) -> bool {
    // 1. 重试次数已达上限
    // 2. WebSocket 已启用
    // 3. 尚未回退到 HTTP
    if !self.websocket_enabled || self.http_fallback_active {
        return false;
    }

    // 激活 HTTP 回退
    self.http_fallback_active = true;
    true
}
```

### 回退的粘性

重要设计：**回退是粘性的（sticky）**

一旦回退到 HTTP，整个会话期间保持 HTTP：

```rust
// 测试验证：回退后后续轮次继续使用 HTTP
#[tokio::test]
async fn websocket_fallback_is_sticky_across_turns() -> Result<()> {
    // 第一轮：WebSocket 失败后回退到 HTTP
    test.submit_turn("first").await?;

    // 第二轮：直接使用 HTTP，不再尝试 WebSocket
    test.submit_turn("second").await?;

    assert_eq!(websocket_attempts, 4);  // 只在第一轮
    assert_eq!(http_attempts, 2);        // 两轮都使用 HTTP
}
```

**设计理由**：
- 避免每轮都经历 WebSocket 失败 → 重试 → 回退的循环
- 减少延迟和服务器负载
- 简化故障排查

---

## 流错误事件

### StreamErrorEvent 结构

错误通过事件流通知 UI/前端：

```rust
#[derive(Debug, Clone, Deserialize, Serialize, JsonSchema, TS)]
pub struct StreamErrorEvent {
    pub message: String,
    #[serde(default)]
    pub codex_error_info: Option<CodexErrorInfo>,
    /// 底层流失败的详细信息
    #[serde(default)]
    pub additional_details: Option<String>,
}
```

### 错误通知实现

```rust
pub(crate) async fn notify_stream_error(
    &self,
    turn_context: &TurnContext,
    message: impl Into<String>,
    err: CodexErr,
) {
    let event = EventMsg::StreamError(StreamErrorEvent {
        message: message.into(),
        codex_error_info: Some(CodexErrorInfo::from(&err)),
        additional_details: Some(format!("{err:#}")),
    });
    self.send_event(turn_context, event).await;
}
```

### 重试消息优化

为减少噪音，Codex 在 release 模式下隐藏首次 WebSocket 重试通知：

```rust
// 在 release 构建中隐藏首次 WebSocket 重试通知
let report_error = retries > 1
    || cfg!(debug_assertions)  // debug 模式始终显示
    || !sess.services.model_client.responses_websocket_enabled(&turn_context.model_info);

if report_error {
    sess.notify_stream_error(...).await;
}
```

**设计理由**：
- WebSocket 瞬断常见，首次重试通常成功
- 避免用户看到一闪而过的"重连中"消息
- Debug 模式保留完整可见性以便诊断

---

## 轮次中断处理

### TurnAborted 事件

当用户主动中断轮次时：

```rust
#[derive(Debug, Clone, Deserialize, Serialize, JsonSchema, TS)]
pub struct TurnAbortedEvent {
    pub turn_id: Option<String>,
    pub reason: TurnAbortReason,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum TurnAbortReason {
    Interrupted,    // 用户中断（Ctrl+C）
    Replaced,       // 被新轮次替换
    ReviewEnded,    // 审查模式结束
}
```

### 中断与重试的区别

| 场景 | 处理方式 | 恢复策略 |
|------|----------|----------|
| 流中断（网络问题） | 自动重试 | 指数退避 + WebSocket 回退 |
| 用户中断（Ctrl+C） | 立即终止 | 不恢复，发送 `TurnAborted` |
| 服务器错误 | 自动重试 | 如果可重试则重试 |
| 配额超限 | 直接失败 | 不重试，提示用户 |

---

## ResponseStreamFailed 细节

### 结构定义

```rust
#[derive(Debug)]
pub struct ResponseStreamFailed {
    pub source: reqwest::Error,
    pub request_id: Option<String>,
}

impl std::fmt::Display for ResponseStreamFailed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "Error while reading the server response: {}{}",
            self.source,
            self.request_id
                .as_ref()
                .map(|id| format!(", request id: {id}"))
                .unwrap_or_default()
        )
    }
}
```

**设计优点**：
- 保留原始错误以便调试
- 包含 request_id 便于服务端追踪
- 用户友好的错误消息

---

## 测试验证

### WebSocket 回退测试

```rust
#[tokio::test]
async fn websocket_fallback_switches_to_http_after_retries_exhausted() -> Result<()> {
    let server = responses::start_mock_server().await;

    // 配置：允许 2 次重试
    config.model_provider.stream_max_retries = Some(2);

    test.submit_turn("hello").await?;

    // 验证：4 次 WebSocket 尝试（预连接 + 初始 + 2 次重试）
    // 然后 1 次 HTTP 请求
    assert_eq!(websocket_attempts, 4);
    assert_eq!(http_attempts, 1);
}
```

### 流错误隐藏测试

```rust
#[tokio::test]
async fn websocket_fallback_hides_first_websocket_retry_stream_error() -> Result<()> {
    // 收集所有 StreamError 事件
    let mut stream_error_messages = Vec::new();

    loop {
        let event = codex.next_event().await?;
        match event.msg {
            EventMsg::StreamError(e) => stream_error_messages.push(e.message),
            EventMsg::TurnComplete(_) => break,
            _ => {}
        }
    }

    // Release 模式：只显示 "Reconnecting... 2/2"
    // Debug 模式：显示 "Reconnecting... 1/2" 和 "Reconnecting... 2/2"
    let expected = if cfg!(debug_assertions) {
        vec!["Reconnecting... 1/2", "Reconnecting... 2/2"]
    } else {
        vec!["Reconnecting... 2/2"]
    };
    assert_eq!(stream_error_messages, expected);
}
```

### 轮次中断测试

```rust
#[tokio::test]
async fn turn_interrupt_aborts_running_turn() -> Result<()> {
    // 启动长时间运行的命令
    let turn_req = mcp.send_turn_start_request(...).await?;

    // 等待命令启动
    tokio::time::sleep(Duration::from_secs(1)).await;

    // 发送中断请求
    let interrupt_id = mcp.send_turn_interrupt_request(...).await?;

    // 验证轮次状态为 Interrupted
    assert_eq!(completed.turn.status, TurnStatus::Interrupted);
}
```

---

## 最佳实践

### 1. 错误分类原则

```rust
// 好的做法：区分用户错误和系统错误
impl CodexErr {
    pub fn is_retryable(&self) -> bool {
        match self {
            // 用户错误：不重试
            UserError(_) | PermissionDenied(_) => false,

            // 系统错误：可能恢复，可以重试
            NetworkError(_) | ServerError(_) => true,
        }
    }
}
```

### 2. 优雅的降级策略

```rust
// 多层回退：WebSocket → HTTP → 错误提示
async fn execute_with_fallback() -> Result<Output> {
    // 尝试 WebSocket
    if let Ok(output) = try_websocket().await {
        return Ok(output);
    }

    // 回退到 HTTP
    warn!("WebSocket failed, falling back to HTTP");
    if let Ok(output) = try_http().await {
        return Ok(output);
    }

    // 最终失败
    Err(Error::ServiceUnavailable)
}
```

### 3. 用户反馈优化

```rust
// 避免信息过载：隐藏瞬态错误
if retries > 1 || !is_transient_error(&err) {
    notify_user(&format!("Reconnecting... ({retries}/{max})"));
}
```

---

## 关键要点

1. **明确的错误分类**：`is_retryable()` 方法是核心，明确区分可恢复和不可恢复错误

2. **指数退避**：避免频繁重试导致服务器过载，同时保证快速恢复

3. **粘性回退**：一旦回退到 HTTP，整个会话保持，避免重复失败循环

4. **用户体验优先**：隐藏首次重试通知，只在必要时打扰用户

5. **完整的可观测性**：保留原始错误、request_id，便于调试和追踪

6. **区分中断与错误**：用户主动中断（Ctrl+C）与流中断不同，处理方式完全不同

---

## 相关文档

- [Codex LLM 抽象层](../architecture/codex-llm-abstraction.md) - ModelClient 错误处理设计
- [Codex 流式处理](../streaming/codex-streaming.md) - WebSocket/SSE 实现细节
- [结构化错误与重试](./structured-errors-retry.md) - LangChain 错误处理对比

---

*创建时间：2026-03-04*
*更新时间：2026-03-04*
