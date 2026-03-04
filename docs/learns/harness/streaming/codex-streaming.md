---
tags: streaming, websocket, realtime, async, codex, harness
---

# Codex 流式处理架构

> **范围**：深入分析 OpenAI Codex 的流式处理机制，包括 WebSocket 实时对话、SSE 回退、流事件处理和音频流处理
>
> **综合自**：codex (openai/codex)
>
> **优先级**：P1

---

## 概述

Codex 实现了多层级的流式处理架构，支持从低延迟实时音频对话到高可靠性 HTTP 回退的完整谱系。核心设计目标是在保证可靠性的前提下最小化延迟。

流式层级：
1. **WebSocket 实时流** - 最低延迟，双向通信
2. **HTTP SSE 流** - 高可靠性，单向服务器推送
3. **增量请求流** - 减少网络传输的优化机制

---

## 实时对话架构

### RealtimeConversationManager

Codex 使用专门的 `RealtimeConversationManager` 管理实时对话的生命周期：

```rust
pub(crate) struct RealtimeConversationManager {
    state: Mutex<Option<ConversationState>>,
}

struct ConversationState {
    audio_tx: Sender<RealtimeAudioFrame>,
    user_text_tx: Sender<String>,
    handoff: RealtimeHandoffState,
    task: JoinHandle<()>,
    realtime_active: Arc<AtomicBool>,
}
```

**设计特点**：
- 使用 `async_channel` 进行异步消息传递
- 有界队列防止内存无限增长
- 原子标志位跟踪对话状态

### 队列配置

```rust
const AUDIO_IN_QUEUE_CAPACITY: usize = 256;
const USER_TEXT_IN_QUEUE_CAPACITY: usize = 64;
const HANDOFF_OUT_QUEUE_CAPACITY: usize = 64;
const OUTPUT_EVENTS_QUEUE_CAPACITY: usize = 256;
```

**设计理由**：
- 音频队列最大（256帧），保证流畅输入
- 文本队列较小（64条），用户输入频率较低
- 有界队列防止背压导致的内存问题

---

## WebSocket 连接管理

### 连接生命周期

```rust
pub(crate) async fn start(
    &self,
    api_provider: ApiProvider,
    extra_headers: Option<HeaderMap>,
    prompt: String,
    model: Option<String>,
    session_id: Option<String>,
) -> CodexResult<(Receiver<RealtimeEvent>, Arc<AtomicBool>)> {
    // 1. 清理之前的状态
    if let Some(state) = previous_state {
        state.realtime_active.store(false, Ordering::Relaxed);
        state.task.abort();
        let _ = state.task.await;
    }

    // 2. 配置会话
    let session_config = RealtimeSessionConfig {
        instructions: prompt,
        model,
        session_id,
    };

    // 3. 建立 WebSocket 连接
    let client = RealtimeWebsocketClient::new(api_provider);
    let connection = client.connect(session_config, ...).await?;

    // 4. 创建通信通道
    let (audio_tx, audio_rx) = async_channel::bounded(AUDIO_IN_QUEUE_CAPACITY);
    let (user_text_tx, user_text_rx) = async_channel::bounded(USER_TEXT_IN_QUEUE_CAPACITY);

    // 5. 启动实时输入任务
    let task = spawn_realtime_input_task(
        writer, events, user_text_rx, handoff_output_rx, audio_rx, events_tx, handoff
    );
}
```

### 实时事件处理

```rust
pub(crate) enum RealtimeEvent {
    SessionUpdated {
        session_id: String,
        instructions: Option<String>,
    },
    AudioOut(RealtimeAudioFrame),
    ConversationItemAdded(Value),
    ConversationItemDone {
        item_id: String,
    },
    HandoffRequested(RealtimeHandoffRequested),
    Error(String),
}
```

---

## 输入处理任务

### spawn_realtime_input_task

实时输入任务协调多个输入源：

```rust
fn spawn_realtime_input_task(
    mut writer: RealtimeWebsocketWriter,
    mut events: RealtimeWebsocketEvents,
    user_text_rx: Receiver<String>,
    handoff_output_rx: Receiver<HandoffOutput>,
    audio_rx: Receiver<RealtimeAudioFrame>,
    events_tx: Sender<RealtimeEvent>,
    handoff: RealtimeHandoffState,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            tokio::select! {
                // 处理音频输入
                Ok(frame) = audio_rx.recv() => {
                    if let Err(e) = writer.send_audio(frame).await {
                        error!("Failed to send audio: {}", e);
                        break;
                    }
                }

                // 处理文本输入
                Ok(text) = user_text_rx.recv() => {
                    if let Err(e) = writer.send_text(text).await {
                        error!("Failed to send text: {}", e);
                        break;
                    }
                }

                // 处理交接输出
                Ok(output) = handoff_output_rx.recv() => {
                    if let Err(e) = writer.send_handoff_output(...).await {
                        error!("Failed to send handoff: {}", e);
                        break;
                    }
                }

                // 处理服务器事件
                Some(event) = events.next() => {
                    if let Err(e) = handle_server_event(event, &events_tx, &handoff).await {
                        error!("Failed to handle event: {}", e);
                        break;
                    }
                }

                else => break,
            }
        }
    })
}
```

**关键设计**：
- 使用 `tokio::select!` 同时处理多个输入源
- 任一通道关闭或出错时任务退出
- 音频、文本、交接三种输入类型统一处理

---

## SSE 回退机制

### 流事件处理

当 WebSocket 不可用时，Codex 回退到 HTTP SSE：

```rust
pub(crate) async fn handle_output_item_done(
    ctx: &mut HandleOutputCtx,
    item: ResponseItem,
    previously_active_item: Option<TurnItem>,
) -> Result<OutputItemResult> {
    match ToolRouter::build_tool_call(ctx.sess.as_ref(), item.clone()).await {
        // 模型发出工具调用
        Ok(Some(call)) => {
            tracing::info!("ToolCall: {} {}", call.tool_name, payload_preview);

            // 立即持久化项目
            record_completed_response_item(ctx.sess.as_ref(), ctx.turn_context.as_ref(), &item).await;

            // 排队工具执行
            let cancellation_token = ctx.cancellation_token.child_token();
            let tool_future = Box::pin(
                ctx.tool_runtime.clone().handle_tool_call(call, cancellation_token)
            );

            output.needs_follow_up = true;
            output.tool_future = Some(tool_future);
        }

        // 无工具调用：转换为轮次项目
        Ok(None) => {
            if let Some(turn_item) = handle_non_tool_response_item(&item, plan_mode) {
                ctx.sess.emit_turn_item_completed(&ctx.turn_context, turn_item).await;
            }
            record_completed_response_item(...).await;
        }

        // 错误处理
        Err(FunctionCallError::MissingLocalShellCallId) => {
            // 将错误反馈到历史记录
        }
    }
}
```

### InFlightFuture 类型

```rust
pub(crate) type InFlightFuture<'f> =
    Pin<Box<dyn Future<Output = Result<ResponseInputItem>> + Send + 'f>>;

pub(crate) struct OutputItemResult {
    pub last_agent_message: Option<String>,
    pub needs_follow_up: bool,  // 是否需要继续轮次
    pub tool_future: Option<InFlightFuture<'static>>,
}
```

**设计优点**：
- 工具调用异步执行，不阻塞流处理
- `needs_follow_up` 标志控制轮次是否继续
- 立即持久化保证历史一致性

---

## 流事件工具

### 输出文本处理

```rust
pub(crate) fn raw_assistant_output_text_from_item(item: &ResponseItem) -> Option<String> {
    if let ResponseItem::Message { role, content, .. } = item
        && role == "assistant"
    {
        let combined = content
            .iter()
            .filter_map(|ci| match ci {
                ContentItem::OutputText { text } => Some(text.as_str()),
                _ => None,
            })
            .collect::<String>();
        return Some(combined);
    }
    None
}
```

### 引用剥离

```rust
fn strip_hidden_assistant_markup(text: &str, plan_mode: bool) -> String {
    let (without_citations, _) = strip_citations(text);
    if plan_mode {
        strip_proposed_plan_blocks(&without_citations)
    } else {
        without_citations
    }
}
```

---

## WebSocket 预热机制

### Prewarm 流程

```rust
/// WebSocket prewarm 是一个 v2-only 的 `response.create` 请求，generate=false
/// 它等待完成，以便后续请求可以复用同一连接和 previous_response_id
```

预热流程：
1. 发送 `generate=false` 的预检请求
2. 建立 WebSocket 连接
3. 缓存连接供后续使用
4. 后续请求直接复用，无需重新握手

**性能优势**：
- 消除首次请求的握手延迟
- 复用 `previous_response_id` 保持上下文
- 失败时计入正常重试逻辑

---

## 增量请求优化

### 请求差异检测

Codex 在 WebSocket 上支持增量请求，只发送变化部分：

```rust
#[derive(Debug, Default)]
struct WebsocketSession {
    connection: Option<ApiWebSocketConnection>,
    last_request: Option<ResponsesApiRequest>,  // 缓存上次请求
    last_response_rx: Option<oneshot::Receiver<LastResponse>>,
}
```

**优化策略**：
- 比较当前请求与 `last_request`
- 如果是增量扩展，只发送差异
- 大幅减少大上下文场景下的网络传输

---

## 实时音频流

### 音频帧结构

```rust
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq, JsonSchema, TS)]
pub struct RealtimeAudioFrame {
    pub data: String,           // Base64 编码的音频数据
    pub sample_rate: u32,       // 采样率
    pub num_channels: u16,      // 通道数
    pub samples_per_channel: Option<u32>,
}
```

### 音频输入处理

```rust
pub(crate) async fn audio_in(&self, frame: RealtimeAudioFrame) -> CodexResult<()> {
    let sender = {
        let guard = self.state.lock().await;
        guard.as_ref().map(|state| state.audio_tx.clone())
    };

    let Some(sender) = sender else {
        return Err(CodexErr::InvalidRequest("conversation is not running".to_string()));
    };

    match sender.try_send(frame) {
        Ok(()) => Ok(()),
        Err(TrySendError::Full(_)) => {
            warn!("dropping input audio frame due to full queue");
            Ok(())  // 优雅丢弃，不中断对话
        }
        Err(TrySendError::Closed(_)) => Err(...),
    }
}
```

**设计特点**：
- 队列满时丢弃旧帧，保证实时性
- 不阻塞，避免音频输入延迟
- 通道关闭时返回明确错误

---

## 最佳实践

### 1. 有界队列使用

```rust
// 好的做法：使用有界队列防止内存问题
let (tx, rx) = async_channel::bounded::<T>(CAPACITY);

// 避免：无界通道可能导致 OOM
let (tx, rx) = async_channel::unbounded::<T>();
```

### 2. 优雅关闭

```rust
// 清理时先标记状态，再中止任务
state.realtime_active.store(false, Ordering::Relaxed);
state.task.abort();
let _ = state.task.await;  // 等待任务结束
```

### 3. 错误隔离

```rust
// 每个输入源独立处理错误，不互相影响
tokio::select! {
    Ok(frame) = audio_rx.recv() => { ... }
    Err(e) = audio_rx.recv() => {
        error!("Audio channel error: {}", e);
        break;
    }
}
```

---

## 比较矩阵

| 特性 | WebSocket | HTTP SSE |
|------|-----------|----------|
| 延迟 | 极低（双向） | 较低（单向） |
| 可靠性 | 需处理重连 | 更稳定 |
| 适用场景 | 实时对话 | 普通代码生成 |
| 复杂度 | 高 | 低 |
| 增量请求 | 支持 | 不支持 |

---

## 关键要点

1. **多层流式架构**：WebSocket 优先，SSE 回退，保证最佳用户体验

2. **有界队列**：所有异步通道使用有界队列，防止背压和内存问题

3. **并行输入处理**：使用 `tokio::select!` 同时处理音频、文本、交接等多种输入

4. **增量优化**：WebSocket 支持增量请求，大幅减少大上下文场景的网络传输

5. **状态一致性**：流事件立即持久化，保证历史记录和 UI 状态同步

---

## 相关文档

- [Codex LLM 抽象层](../architecture/codex-llm-abstraction.md) - 客户端架构设计
- [Codex 上下文管理](../context-management/codex-context-management.md) - 状态和历史管理
- [异步流式优先设计](../streaming/async-streaming-first-class.md) - kimi-cli 的流式实现对比

---

*创建时间：2026-03-04*
*更新时间：2026-03-04*
