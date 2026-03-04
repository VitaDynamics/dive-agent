---
tags: architecture, llm-abstraction, client, codex, harness
---

# Codex LLM 抽象层设计

> **范围**：深入分析 OpenAI Codex 的 LLM 客户端抽象架构，包括 ModelClient、ModelClientSession 的设计，以及与 OpenAI API 的交互模式
>
> **综合自**：codex (openai/codex)
>
> **优先级**：P1

---

## 概述

Codex 的 LLM 抽象层设计采用了清晰的分层架构，将**会话级状态**（session-scoped）与**轮次级状态**（turn-scoped）分离。这种设计使得客户端能够高效地管理 WebSocket 连接、处理认证、并实现复杂的流式交互模式。

核心设计哲学：
1. **生命周期分离**：会话级配置与轮次级请求解耦
2. **连接复用**：WebSocket 连接在轮次内保持，支持增量请求
3. **优雅降级**：WebSocket 失败时自动回退到 HTTP SSE
4. **状态隔离**：每轮次有独立的 `turn_state` 用于 sticky routing

---

## 核心抽象

### ModelClient - 会话级客户端

`ModelClient` 是会话级别的 LLM 客户端，持有跨越多个轮次的稳定配置：

```rust
#[derive(Debug, Clone)]
pub struct ModelClient {
    state: Arc<ModelClientState>,
}

struct ModelClientState {
    auth_manager: Option<Arc<AuthManager>>,
    conversation_id: ThreadId,
    provider: ModelProviderInfo,
    session_source: SessionSource,
    model_verbosity: Option<VerbosityConfig>,
    responses_websockets_enabled_by_feature: bool,
    enable_request_compression: bool,
    include_timing_metrics: bool,
    beta_features_header: Option<String>,
    disable_websockets: AtomicBool,
    cached_websocket_session: StdMutex<WebsocketSession>,
}
```

**设计理由**：
- 使用 `Arc` 实现轻量级克隆，便于在多任务间共享
- `AtomicBool` 用于线程安全的 WebSocket 禁用标志
- `StdMutex` 保护 WebSocket 会话缓存，支持连接复用

### ModelClientSession - 轮次级会话

每轮对话创建一个新的 `ModelClientSession`，隔离轮次特定的状态：

```rust
pub struct ModelClientSession {
    client: ModelClient,
    websocket_session: WebsocketSession,
    /// Turn state for sticky routing - 必须在同轮次内保持一致
    turn_state: Arc<OnceLock<String>>,
}
```

**关键设计决策**：

1. **Sticky Routing**：`turn_state` 使用 `OnceLock` 确保在轮次内只设置一次，从服务器获取后保持不变
2. **连接复用**：`websocket_session` 缓存 WebSocket 连接，支持增量请求
3. **自动清理**：通过 `Drop` trait 在会话结束时自动缓存连接

```rust
impl Drop for ModelClientSession {
    fn drop(&mut self) {
        let websocket_session = std::mem::take(&mut self.websocket_session);
        self.client.store_cached_websocket_session(websocket_session);
    }
}
```

---

## 流式架构

### WebSocket 优先策略

Codex 优先使用 WebSocket 进行流式通信，但提供优雅降级机制：

```rust
pub fn responses_websocket_enabled(&self, model_info: &ModelInfo) -> bool {
    // 检查提供者支持和功能开关
    if !self.state.provider.supports_websockets
        || self.state.disable_websockets.load(Ordering::Relaxed)
    {
        return false;
    }
    // 功能开关或模型偏好
    self.state.responses_websockets_enabled_by_feature || model_info.prefer_websockets
}
```

### 连接预热（Prewarm）

为了减少延迟，Codex 实现了 WebSocket 预热机制：

```rust
/// WebSocket prewarm 是 v2-only 的 `response.create` 请求，generate=false
/// 它等待完成，以便后续请求可以复用同一连接和 previous_response_id
```

预热的好处：
- 提前建立 WebSocket 连接
- 后续请求可以直接复用，减少握手延迟
- 失败时计入正常重试逻辑

### 流式回退机制

当 WebSocket 失败时，自动回退到 HTTP SSE：

```rust
enum WebsocketStreamOutcome {
    Stream(ResponseStream),
    FallbackToHttp,
}

fn activate_http_fallback(&self, websocket_enabled: bool) -> bool {
    websocket_enabled && !self.client.state.disable_websockets.swap(true, Ordering::Relaxed)
}
```

**设计理由**：
- 会话级回退：一旦回退，整个会话使用 HTTP
- 避免频繁切换带来的不确定性
- 使用 `AtomicBool` 保证线程安全

---

## 协议层抽象

### SQ/EQ 模式

Codex 使用 Submission Queue (SQ) / Event Queue (EQ) 模式进行异步通信：

```rust
/// Submission Queue Entry - 来自用户的请求
#[derive(Debug, Clone, Deserialize, Serialize, JsonSchema)]
pub struct Submission {
    pub id: String,
    pub op: Op,
    pub trace: Option<W3cTraceContext>,
}

/// Event - 发送到用户的事件
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Event {
    pub id: String,
    pub event: EventMsg,
}
```

### Op 枚举 - 统一操作接口

所有用户操作封装在 `Op` 枚举中：

```rust
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
#[non_exhaustive]
pub enum Op {
    /// 中断当前任务
    Interrupt,

    /// 启动实时对话流
    RealtimeConversationStart(ConversationStartParams),

    /// 发送音频输入到实时对话
    RealtimeConversationAudio(ConversationAudioParams),

    /// 发送文本输入到实时对话
    RealtimeConversationText(ConversationTextParams),

    /// 关闭实时对话流
    RealtimeConversationClose,

    /// 用户轮次输入（旧版）
    UserInput { ... },

    /// 用户轮次输入（新版）- 包含完整上下文
    UserTurn { ... },

    /// 覆盖持久化轮次上下文
    OverrideTurnContext { ... },

    // ... 其他操作
}
```

**设计理由**：
- 使用 `#[serde(tag = "type")]` 实现类型安全的序列化
- `#[non_exhaustive]` 允许未来扩展而不破坏兼容性
- `UserTurn` 包含完整上下文（cwd, approval_policy, sandbox_policy, model）

---

## 模型响应抽象

### ResponseItem 枚举

Codex 使用统一的 `ResponseItem` 枚举表示所有模型输出：

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ResponseItem {
    Message {
        id: Option<String>,
        role: String,
        content: Vec<ContentItem>,
        end_turn: Option<bool>,
        phase: Option<MessagePhase>,  // Commentary vs FinalAnswer
    },
    Reasoning {
        id: String,
        summary: Vec<ReasoningItemReasoningSummary>,
        content: Option<Vec<ReasoningItemContent>>,
        encrypted_content: Option<String>,
    },
    LocalShellCall { ... },
    FunctionCall { ... },
    FunctionCallOutput { ... },
    WebSearchCall { ... },
    // ...
}
```

### ContentItem 层次结构

```rust
pub enum ContentItem {
    InputText { text: String },
    InputImage { image_url: String },
    OutputText { text: String },
}
```

**设计优点**：
- 类型安全：编译时保证所有变体都被处理
- 序列化友好：serde 自动处理 JSON 转换
- 可扩展：新增响应类型不需要修改现有代码

---

## 工具调用抽象

### ToolRouter 模式

Codex 使用路由器模式处理不同类型的工具调用：

```rust
pub(crate) struct ToolRouter;

impl ToolRouter {
    pub async fn build_tool_call(
        sess: &Session,
        item: ResponseItem,
    ) -> Result<Option<ToolCall>, FunctionCallError> {
        match item {
            ResponseItem::FunctionCall { .. } => { ... }
            ResponseItem::LocalShellCall { .. } => { ... }
            ResponseItem::WebSearchCall { .. } => { ... }
            _ => Ok(None),
        }
    }
}
```

### 并行工具执行

```rust
pub(crate) struct ToolCallRuntime { ... }

pub(crate) async fn handle_tool_call(
    &self,
    call: ToolCall,
    cancellation_token: CancellationToken,
) -> Result<ResponseInputItem> {
    // 支持并发执行多个工具调用
}
```

---

## 最佳实践

### 1. 生命周期管理

```rust
// 好的做法：每轮创建新会话
pub fn new_session(&self) -> ModelClientSession {
    ModelClientSession {
        client: self.clone(),
        websocket_session: self.take_cached_websocket_session(),
        turn_state: Arc::new(OnceLock::new()),
    }
}

// 避免：跨轮次重用会话，会导致 sticky routing 错误
```

### 2. 错误处理与回退

```rust
// WebSocket 失败时自动回退到 HTTP
match self.try_websocket_stream(...).await {
    Ok(stream) => WebsocketStreamOutcome::Stream(stream),
    Err(_) if self.activate_http_fallback(websocket_enabled) => {
        // 记录降级并继续
        WebsocketStreamOutcome::FallbackToHttp
    }
    Err(e) => Err(e),
}
```

### 3. 增量请求优化

Codex 支持增量 WebSocket 请求，只发送变化的部分：

```rust
// 缓存上次请求，比较差异
last_request: Option<ResponsesApiRequest>,

// 如果当前请求是上次请求的增量扩展，
// 只发送差异部分以减少网络传输
```

---

## 关键要点

1. **清晰的生命周期分离**：会话级状态与轮次级状态严格分离，避免交叉污染

2. **连接复用策略**：WebSocket 连接在轮次内复用，通过 `Drop` trait 自动缓存

3. **优雅降级设计**：WebSocket → HTTP 的自动回退，保证可靠性

4. **类型安全的协议**：使用 Rust 的强类型系统和 serde 实现类型安全的 API 通信

5. **Sticky Routing**：通过 `turn_state` 确保同一轮次的请求路由到同一服务器实例

---

## 相关文档

- [Codex 流式处理设计](./codex-streaming.md) - WebSocket 和 SSE 实现细节
- [Codex 上下文管理](./codex-context-management.md) - 对话历史和状态管理
- [Pydantic AI 流式处理](../streaming/streaming-tool-assembly.md) - 对比其他框架的流式实现

---

*创建时间：2026-03-04*
*更新时间：2026-03-04*
