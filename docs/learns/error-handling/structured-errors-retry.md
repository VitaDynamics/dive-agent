# 结构化错误分类与自动重试设计

> **Related topics**: [[pydantic-ai-agent-graph]], [[langchain-runnable]], [[llm-error-handling]]

## Overview

本文分析五个 LLM 框架中的结构化错误分类与自动重试机制：

| 框架 | 语言 | 定位 |
|------|------|------|
| **pydantic-ai** | Python | 结构化输出优先的 Agent 框架 |
| **langchain** | Python | 通用 LLM 编排框架 |
| **pi-mono** | TypeScript | VSCode 扩展 AI Agent 框架 |
| **kosong** | Python | 轻量级 Chat Provider 库 |
| **republic** | Python | 统一接口 LLM 客户端 |

核心关注点：错误层次结构设计、重试策略实现、错误恢复机制以及 Callback 系统中的错误传播。

## Key Concepts

### 1. 错误分类层次结构 (Error Hierarchy)

#### pydantic-ai 的错误层次

```
Exception
├── ModelRetry              # 工具函数重试信号
├── CallDeferred            # 延迟工具调用
├── ApprovalRequired        # 需要人工审批
├── UserError               # 开发者使用错误
└── AgentRunError           # Agent 运行期错误基类
    ├── UsageLimitExceeded      # 用量限制超出
    ├── ConcurrencyLimitExceeded # 并发限制超出
    ├── UnexpectedModelBehavior  # 模型异常行为
    │   └── ContentFilterError   # 内容过滤触发
    ├── ModelAPIError            # 模型 API 错误基类
    │   └── ModelHTTPError       # HTTP 错误 (4xx/5xx)
    └── IncompleteToolCall       # 工具调用不完整
```

**关键设计原则**：
- **分层明确**: `UserError` (开发者错误) vs `AgentRunError` (运行时错误)
- **可恢复性标记**: `ModelRetry` 表示可重试，`CallDeferred`/`ApprovalRequired` 表示需要外部干预
- **上下文丰富**: `ModelHTTPError` 包含 status_code、body、model_name

```python
# pydantic-ai/pydantic_ai_slim/pydantic_ai/exceptions.py
class ModelHTTPError(ModelAPIError):
    """Raised when an model provider response has a status code of 4xx or 5xx."""
    status_code: int
    body: object | None

    def __init__(self, status_code: int, model_name: str, body: object | None = None):
        self.status_code = status_code
        self.body = body
        message = f'status_code: {status_code}, model_name: {model_name}, body: {body}'
        super().__init__(model_name=model_name, message=message)
```

#### langchain 的错误层次

```
Exception
└── LangChainException
    ├── TracerException
    ├── OutputParserException    # 输出解析错误 (可发送到 LLM 修复)
    └── ContextOverflowError     # 上下文溢出
```

**关键设计特点**：
- **ErrorCode 枚举**: 标准化错误代码 (`OUTPUT_PARSING_FAILURE`, `MODEL_RATE_LIMIT` 等)
- **可修复标记**: `OutputParserException.send_to_llm` 允许将错误反馈给模型

```python
# langchain/libs/core/langchain_core/exceptions.py
class OutputParserException(ValueError, LangChainException):
    def __init__(
        self,
        error: Any,
        observation: str | None = None,
        llm_output: str | None = None,
        send_to_llm: bool = False,
    ):
        self.observation = observation
        self.llm_output = llm_output
        self.send_to_llm = send_to_llm  # 是否反馈给 LLM 修复
```

### 2. 自动重试机制 (Automatic Retry)

#### pydantic-ai: 基于 Tenacity 的 HTTP 传输层重试

```python
# pydantic-ai/pydantic_ai_slim/pydantic_ai/retries.py
class RetryConfig(TypedDict, total=False):
    """Configuration for tenacity-based retrying."""
    sleep: Callable[[int | float], None | Awaitable[None]]
    stop: StopBaseT           # 停止策略
    wait: WaitBaseT           # 等待策略
    retry: SyncRetryBaseT | RetryBaseT  # 重试条件
    before: Callable[[RetryCallState], None | Awaitable[None]]
    after: Callable[[RetryCallState], None | Awaitable[None]]
    reraise: bool             # 是否重新抛出异常

class TenacityTransport(BaseTransport):
    """Synchronous HTTP transport with tenacity-based retry functionality."""

    def handle_request(self, request: Request) -> Response:
        @retry(**self.config)
        def handle_request(req: Request) -> Response:
            response = self.wrapped.handle_request(req)
            response.request = req
            if self.validate_response:
                try:
                    self.validate_response(response)
                except Exception:
                    response.close()
                    raise
            return response
        return handle_request(request)
```

**Retry-After 支持**：
```python
def wait_retry_after(
    fallback_strategy: Callable[[RetryCallState], float] | None = None,
    max_wait: float = 300
) -> Callable[[RetryCallState], float]:
    """Wait strategy that respects HTTP Retry-After headers."""
    def wait_func(state: RetryCallState) -> float:
        exc = state.outcome.exception() if state.outcome else None
        if isinstance(exc, HTTPStatusError):
            retry_after = exc.response.headers.get('retry-after')
            if retry_after:
                try:
                    wait_seconds = int(retry_after)
                    return min(float(wait_seconds), max_wait)
                except ValueError:
                    # Try parsing as HTTP date
                    retry_time = parsedate_to_datetime(retry_after)
                    wait_seconds = (retry_time - now).total_seconds()
                    return min(wait_seconds, max_wait)
        return fallback_strategy(state)
    return wait_func
```

#### langchain: RunnableRetry 包装器

```python
# langchain/libs/core/langchain_core/runnables/retry.py
class RunnableRetry(RunnableBindingBase[Input, Output]):
    """Retry a Runnable if it fails."""

    retry_exception_types: tuple[type[BaseException], ...] = (Exception,)
    wait_exponential_jitter: bool = True
    exponential_jitter_params: ExponentialJitterParams | None = None
    max_attempt_number: int = 3

    def _invoke(self, input_, run_manager, config, **kwargs):
        for attempt in self._sync_retrying(reraise=True):
            with attempt:
                result = super().invoke(
                    input_,
                    self._patch_config(config, run_manager, attempt.retry_state),
                    **kwargs,
                )
            if attempt.retry_state.outcome and not attempt.retry_state.outcome.failed:
                attempt.retry_state.set_result(result)
        return result
```

**使用方式**：
```python
# 链式调用添加重试
chain = template | model.with_retry(
    retry_if_exception_type=(ValueError,),
    wait_exponential_jitter=True,
    stop_after_attempt=5,
)
```

### 3. 模型级 Fallback 机制

#### pydantic-ai: FallbackModel

```python
# pydantic-ai/pydantic_ai_slim/pydantic_ai/models/fallback.py
class FallbackModel(Model):
    """A model that uses one or more fallback models upon failure."""

    models: list[Model]
    _fallback_on: Callable[[Exception], bool]

    async def request(self, messages, model_settings, model_request_parameters):
        exceptions: list[Exception] = []

        for model in self.models:
            try:
                response = await model.request(messages, model_settings, model_request_parameters)
            except Exception as exc:
                if self._fallback_on(exc):
                    exceptions.append(exc)
                    continue
                raise exc
            return response

        raise FallbackExceptionGroup('All models from FallbackModel failed', exceptions)
```

#### langchain: RunnableWithFallbacks

```python
# langchain/libs/core/langchain_core/runnables/fallbacks.py
class RunnableWithFallbacks(RunnableSerializable[Input, Output]):
    """Runnable that can fallback to other Runnables if it fails."""

    runnable: Runnable[Input, Output]
    fallbacks: Sequence[Runnable[Input, Output]]
    exceptions_to_handle: tuple[type[BaseException], ...] = (Exception,)
    exception_key: str | None = None  # 将异常传递给 fallback 的 key

    def invoke(self, input, config=None, **kwargs):
        first_error = None
        last_error = None

        for runnable in self.runnables:
            try:
                if self.exception_key and last_error is not None:
                    input[self.exception_key] = last_error
                output = runnable.invoke(input, config, **kwargs)
            except self.exceptions_to_handle as e:
                if first_error is None:
                    first_error = e
                last_error = e
            else:
                return output

        raise first_error
```

### 4. Agent 内部重试逻辑

#### pydantic-ai: GraphAgentState 管理重试计数

```python
# pydantic-ai/pydantic_ai_slim/pydantic_ai/_agent_graph.py
@dataclasses.dataclass(kw_only=True)
class GraphAgentState:
    """State kept across the execution of the agent graph."""
    message_history: list[ModelMessage]
    usage: RunUsage
    retries: int = 0           # 当前重试次数
    run_step: int = 0
    run_id: str

    def increment_retries(
        self,
        max_result_retries: int,
        error: BaseException | None = None,
        model_settings: ModelSettings | None = None,
    ) -> None:
        self.retries += 1
        if self.retries > max_result_retries:
            # 特殊处理：token 限制导致的工具调用不完整
            if (
                self.message_history
                and isinstance(model_response := self.message_history[-1], ModelResponse)
                and model_response.finish_reason == 'length'
                and isinstance(tool_call := model_response.parts[-1], ToolCallPart)
            ):
                raise IncompleteToolCall(
                    f'Model token limit exceeded while generating a tool call'
                )

            message = f'Exceeded maximum retries ({max_result_retries})'
            raise UnexpectedModelBehavior(message) from error
```

**输出验证重试**：
```python
# 在 _run_stream 中处理输出验证失败
try:
    validated = await tool_manager.validate_tool_call(call)
except UnexpectedModelBehavior as e:
    if final_result:
        # 如果已有有效结果，跳过失败的输出工具
        continue
    ctx.state.increment_retries(
        ctx.deps.max_result_retries, error=e, model_settings=ctx.deps.model_settings
    )
    raise
```

### 5. Callback 系统中的错误传播

#### langchain: 错误回调接口

```python
# langchain/libs/core/langchain_core/callbacks/base.py
class LLMManagerMixin:
    def on_llm_error(
        self,
        error: BaseException,
        *,
        run_id: UUID,
        parent_run_id: UUID | None = None,
        tags: list[str] | None = None,
        **kwargs: Any,
    ) -> Any:
        """Run when LLM errors."""

class ChainManagerMixin:
    def on_chain_error(
        self,
        error: BaseException,
        *,
        run_id: UUID,
        parent_run_id: UUID | None = None,
        **kwargs: Any,
    ) -> Any:
        """Run when chain errors."""

class BaseCallbackHandler:
    def on_retry(
        self,
        retry_state: RetryCallState,
        *,
        run_id: UUID,
        parent_run_id: UUID | None = None,
        **kwargs: Any,
    ) -> Any:
        """Run on a retry event."""
```

### 6. 错误映射与转换

#### pydantic-ai: OpenAI 错误映射

```python
# pydantic-ai/pydantic_ai_slim/pydantic_ai/models/openai.py
try:
    response = await self.client.chat.completions.create(...)
except APIStatusError as e:
    if model_response := _check_azure_content_filter(e, self.system, self.model_name):
        return model_response
    if (status_code := e.status_code) >= 400:
        raise ModelHTTPError(status_code=status_code, model_name=self.model_name, body=e.body) from e
    raise
except APIConnectionError as e:
    raise ModelAPIError(model_name=self.model_name, message=e.message) from e
```

#### langchain: 错误响应生成

```python
# langchain/libs/core/langchain_core/language_models/chat_models.py
def _generate_response_from_error(error: BaseException) -> list[ChatGeneration]:
    """Generate a response from an error for tracing purposes."""
    if hasattr(error, "response"):
        response = error.response
        metadata: dict = {}
        if hasattr(response, "json"):
            try:
                metadata["body"] = response.json()
            except Exception:
                metadata["body"] = getattr(response, "text", None)
        if hasattr(response, "headers"):
            metadata["headers"] = dict(response.headers)
        if hasattr(response, "status_code"):
            metadata["status_code"] = response.status_code
        if hasattr(error, "request_id"):
            metadata["request_id"] = error.request_id

        generations = [
            ChatGeneration(message=AIMessage(content="", response_metadata=metadata))
        ]
    else:
        generations = []

    return generations
```

## Code Examples

### pydantic-ai: 完整的重试配置示例

```python
from httpx import Client, HTTPStatusError, HTTPTransport
from tenacity import retry_if_exception_type, stop_after_attempt
from pydantic_ai.retries import RetryConfig, TenacityTransport, wait_retry_after

# 配置带重试的 HTTP 传输层
transport = TenacityTransport(
    RetryConfig(
        retry=retry_if_exception_type(HTTPStatusError),
        wait=wait_retry_after(max_wait=300),  # 尊重 Retry-After 头
        stop=stop_after_attempt(5),
        reraise=True
    ),
    HTTPTransport(),
    validate_response=lambda r: r.raise_for_status()
)
client = Client(transport=transport)

# 模型级 Fallback
from pydantic_ai.models.fallback import FallbackModel
from pydantic_ai.models.openai import OpenAIModel
from pydantic_ai.models.anthropic import AnthropicModel

fallback_model = FallbackModel(
    OpenAIModel('gpt-4'),
    AnthropicModel('claude-3-opus'),
    fallback_on=(ModelAPIError,)  # 只在 API 错误时 fallback
)
```

### langchain: 完整的重试配置示例

```python
from langchain_core.runnables import RunnableLambda
from langchain_openai import ChatOpenAI
from langchain_anthropic import ChatAnthropic

# 模型级 Fallback
model = ChatAnthropic(model="claude-3-haiku").with_fallbacks(
    [ChatOpenAI(model="gpt-3.5-turbo")],
    exceptions_to_handle=(Exception,)
)

# 链式重试
chain = (
    PromptTemplate.from_template("Tell me a joke about {topic}")
    | model.with_retry(
        retry_if_exception_type=(ValueError,),
        wait_exponential_jitter=True,
        stop_after_attempt=5,
    )
    | StrOutputParser()
)

# 带异常传递的 fallback
def when_all_is_lost(inputs):
    error = inputs.get("error")
    return f"Failed after retries. Error: {error}"

chain_with_fallback = chain.with_fallbacks(
    [RunnableLambda(when_all_is_lost)],
    exception_key="error"  # 将异常传递给 fallback
)
```

## Design Decisions

### 1. 分层重试策略

| 层级 | pydantic-ai | langchain | 适用场景 |
|------|-------------|-----------|----------|
| HTTP 传输层 | `TenacityTransport` | - | 网络错误、Rate Limit |
| 模型层 | `FallbackModel` | `RunnableWithFallbacks` | 模型提供商故障 |
| Agent 层 | `GraphAgentState.increment_retries` | - | 输出验证失败 |
| 链层 | - | `RunnableRetry` | 任意 Runnable 失败 |

### 2. 错误分类哲学

**pydantic-ai**:
- 强调**运行时错误**的细分 (`ModelAPIError` vs `UnexpectedModelBehavior`)
- 区分**可重试错误** (`ModelRetry`) 和**需干预错误** (`CallDeferred`, `ApprovalRequired`)
- 保留原始错误链 (`raise ... from e`)

**langchain**:
- 强调**错误修复能力** (`OutputParserException.send_to_llm`)
- 标准化错误代码 (`ErrorCode` 枚举)
- 错误元数据用于追踪 (`_generate_response_from_error`)

### 3. 重试状态管理

**pydantic-ai**:
- 状态存储在 `GraphAgentState` 中
- 与消息历史关联，支持上下文感知重试
- 特殊处理 token 限制导致的工具调用不完整

**langchain**:
- 使用 tenacity 的 `RetryCallState`
- 通过 Callback 系统通知重试事件
- 支持批量操作的部分重试

### 4. 对 Rust LLM 抽象层的启示

1. **错误类型设计**:
```rust
// 建议的错误层次
pub enum LLMError {
    // 用户错误
    UserError { message: String },

    // 运行时错误
    RuntimeError {
        kind: RuntimeErrorKind,
        source: Option<Box<dyn Error>>,
    },
}

pub enum RuntimeErrorKind {
    ModelAPI { status_code: u16, body: Option<String> },
    ContentFilter { reason: String },
    TokenLimit { max_tokens: Option<u32> },
    ToolCallIncomplete,
    ValidationFailed { attempts: u32 },
}

// 可恢复性标记 trait
pub trait Recoverable {
    fn recovery_strategy(&self) -> RecoveryStrategy;
}

pub enum RecoveryStrategy {
    Retry { max_attempts: u32 },
    Fallback { to: ModelId },
    Defer { metadata: Option<Value> },
    Abort,
}
```

2. **重试策略配置**:
```rust
pub struct RetryConfig {
    pub max_attempts: u32,
    pub backoff: BackoffStrategy,
    pub retry_if: Box<dyn Fn(&LLMError) -> bool + Send + Sync>,
    pub on_retry: Option<Box<dyn Fn(&RetryContext) + Send + Sync>>,
}

pub enum BackoffStrategy {
    Fixed { duration: Duration },
    Exponential { initial: Duration, max: Duration, multiplier: f64 },
    RespectRetryAfter { max: Duration },
}
```

3. **Fallback 链设计**:
```rust
pub struct FallbackChain {
    pub models: Vec<Box<dyn LLMModel>>,
    pub fallback_on: Box<dyn Fn(&LLMError) -> bool + Send + Sync>,
    pub exception_propagation: ExceptionPropagation,
}

pub enum ExceptionPropagation {
    None,
    ToNext { key: String },
}
```

4. **与异步生态集成**:
- 使用 `tower::retry::Retry` 或自定义中间件
- 利用 `tokio::time::sleep` 实现退避
- 通过 `tracing` 记录重试事件

## Related Files

### pydantic-ai
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/pydantic-ai/pydantic_ai_slim/pydantic_ai/exceptions.py` - 错误分类定义
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/pydantic-ai/pydantic_ai_slim/pydantic_ai/retries.py` - HTTP 传输层重试
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/pydantic-ai/pydantic_ai_slim/pydantic_ai/_agent_graph.py` - Agent 状态管理和重试逻辑
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/pydantic-ai/pydantic_ai_slim/pydantic_ai/models/fallback.py` - 模型级 Fallback
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/pydantic-ai/pydantic_ai_slim/pydantic_ai/models/openai.py` - 错误映射示例

### langchain
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/langchain/libs/core/langchain_core/exceptions.py` - 基础异常定义
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/langchain/libs/core/langchain_core/runnables/retry.py` - RunnableRetry 实现
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/langchain/libs/core/langchain_core/runnables/fallbacks.py` - RunnableWithFallbacks 实现
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/langchain/libs/core/langchain_core/callbacks/base.py` - 错误回调接口
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/langchain/libs/core/langchain_core/language_models/chat_models.py` - 错误响应生成

---

## Additional Framework Comparisons

### 7. pi-mono (TypeScript AI Agent Framework)

pi-mono 是一个 TypeScript 实现的 AI Agent 框架，采用分层错误处理策略，强调 Provider 级别的错误恢复。

#### 7.1 错误表示方式

不同于 Python 框架的异常层次结构，pi-mono 使用**状态标记 + 错误消息**的方式处理错误：

```typescript
// packages/ai/src/types.ts
export type StopReason = "stop" | "length" | "toolUse" | "error" | "aborted";

export interface AssistantMessage {
    role: "assistant";
    content: (TextContent | ThinkingContent | ToolCall)[];
    api: Api;
    provider: Provider;
    model: string;
    usage: Usage;
    stopReason: StopReason;       // 使用状态标记
    errorMessage?: string;        // 错误详情
    timestamp: number;
}
```

**设计权衡**：
- 优点：简化错误传播，适合流式响应和跨网络边界通信
- 缺点：丢失类型安全，错误处理依赖运行时检查

#### 7.2 Provider 级重试策略

**指数退避 + 服务器延迟提取**：

```typescript
// packages/ai/src/providers/google-gemini-cli.ts
const MAX_RETRIES = 3;
const BASE_DELAY_MS = 1000;

for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    const response = await fetch(...);
    if (response.ok) break;

    if (attempt < MAX_RETRIES && isRetryableError(response.status, errorText)) {
        // 优先使用服务器提供的延迟
        const serverDelay = extractRetryDelay(errorText, response);
        const delayMs = serverDelay ?? BASE_DELAY_MS * 2 ** attempt;

        // 检查延迟上限
        const maxDelayMs = options?.maxRetryDelayMs ?? 60000;
        if (maxDelayMs > 0 && serverDelay && serverDelay > maxDelayMs) {
            throw new Error(`Server requested ${delaySeconds}s retry delay...`);
        }

        await sleep(delayMs, options?.signal);
    }
}
```

**Retry-After 提取逻辑**：

```typescript
function extractRetryDelay(errorText: string, response?: Response): number | undefined {
    const headers = response instanceof Headers ? response : response?.headers;

    // 1. 检查标准 Retry-After 头 (秒或 HTTP date)
    const retryAfter = headers.get("retry-after");
    if (retryAfter) {
        const seconds = Number(retryAfter);
        if (Number.isFinite(seconds)) return seconds * 1000;
        const date = new Date(retryAfter);
        return date.getTime() - Date.now();
    }

    // 2. 检查 x-ratelimit-reset 头
    const rateLimitReset = headers.get("x-ratelimit-reset");

    // 3. 从错误文本解析 (多种模式)
    // Pattern: "Your quota will reset after 18h31m10s"
    // Pattern: "Please retry in 2s"
    // Pattern: "retryDelay": "34.074s"
}
```

#### 7.3 Agent 层自动重试

```typescript
// packages/coding-agent/src/core/agent-session.ts
private _isRetryableError(message: AssistantMessage): boolean {
    if (message.stopReason !== "error") return false;

    // 上下文溢出不通过重试解决，而是通过 compaction
    const contextWindow = this.model?.contextWindow ?? 0;
    if (isContextOverflow(message, contextWindow)) return false;

    const err = message.errorMessage;
    // 正则匹配多种可重试错误模式
    return /overloaded|rate.?limit|too many requests|429|500|502|503|504/i.test(err);
}

private async _handleRetryableError(message: AssistantMessage): Promise<boolean> {
    const settings = this.settingsManager.getRetrySettings();
    if (!settings.enabled) return false;

    this._retryAttempt++;
    if (this._retryAttempt > settings.maxRetries) {
        this._emit({ type: "auto_retry_end", success: false, ... });
        return false;
    }

    const delayMs = settings.baseDelayMs * 2 ** (this._retryAttempt - 1);

    this._emit({
        type: "auto_retry_start",
        attempt: this._retryAttempt,
        maxAttempts: settings.maxRetries,
        delayMs,
        errorMessage: message.errorMessage,
    });

    await sleep(delayMs, this._retryAbortController.signal);
    // ... retry via continue()
}
```

#### 7.4 Endpoint Fallback

```typescript
// packages/ai/src/providers/google-gemini-cli.ts
const DEFAULT_ENDPOINT = "https://cloudcode-pa.googleapis.com";
const ANTIGRAVITY_DAILY_ENDPOINT = "https://daily-cloudcode-pa.sandbox.googleapis.com";
const ANTIGRAVITY_ENDPOINT_FALLBACKS = [ANTIGRAVITY_DAILY_ENDPOINT, DEFAULT_ENDPOINT];

// 在重试循环中切换端点
const endpoint = endpoints[Math.min(attempt, endpoints.length - 1)];
```

#### 7.5 上下文溢出检测

```typescript
// packages/ai/src/utils/overflow.ts
const OVERFLOW_PATTERNS = [
    /prompt is too long/i,                           // Anthropic
    /input is too long for requested model/i,        // Amazon Bedrock
    /exceeds the context window/i,                   // OpenAI
    /input token count.*exceeds the maximum/i,       // Google
    /maximum prompt length is \d+/i,                 // xAI (Grok)
    /exceeded model token limit/i,                   // Kimi For Coding
    /context[_ ]length[_ ]exceeded/i,                // Generic
];
```

---

### 8. kosong (Python Chat Provider Library)

kosong 是一个轻量级的 Python Chat Provider 库，采用**协议驱动**的错误恢复设计，核心特点是将重试责任交给调用方。

#### 8.1 错误类型层次

```python
# src/kosong/chat_provider/__init__.py
class ChatProviderError(Exception): pass

class APIConnectionError(ChatProviderError): pass
class APITimeoutError(ChatProviderError): pass
class APIStatusError(ChatProviderError):
    """API returns 4xx or 5xx status codes"""
    def __init__(self, status_code: int, message: str):
        self.status_code = status_code
        super().__init__(message)

class APIEmptyResponseError(ChatProviderError): pass

# Tool 相关错误
# src/kosong/tooling/error.py
class ToolError(Exception): pass
class ToolNotFoundError(ToolError): pass
class ToolParseError(ToolError): pass      # JSON 解析失败
class ToolValidateError(ToolError): pass   # 参数验证失败
class ToolRuntimeError(ToolError): pass    # 执行时失败
```

#### 8.2 RetryableChatProvider 协议

**核心设计理念**：库只提供**状态恢复钩子**，不重试逻辑本身。

```python
# src/kosong/chat_provider/__init__.py
@runtime_checkable
class RetryableChatProvider(Protocol):
    """Optional interface for providers that can recover from retryable transport errors."""

    def on_retryable_error(self, error: BaseException) -> bool:
        """
        Try to recover provider transport state after a retryable error.
        Returns: Whether recovery action was performed.
        """
```

**实现示例** (重新创建客户端)：

```python
# src/kosong/chat_provider/kimi.py
class KimiChatProvider:
    def on_retryable_error(self, error: BaseException) -> bool:
        # 发生可重试错误时，重新创建 OpenAI 客户端
        old_client = self._client
        self._client = self._create_client()
        if old_client is not None:
            old_client.close()
        return True
```

#### 8.3 Provider 错误映射

```python
# src/kosong/chat_provider/openai_common.py
def convert_error(error: OpenAIError | httpx.HTTPError) -> ChatProviderError:
    match error:
        case openai.APIStatusError():
            return APIStatusError(error.status_code, error.message)
        case openai.APIConnectionError():
            return APIConnectionError(error.message)
        case openai.APITimeoutError():
            return APITimeoutError(error.message)
        case httpx.TimeoutException():
            return APITimeoutError(str(error))
        case httpx.NetworkError():
            return APIConnectionError(str(error))
        case httpx.HTTPStatusError():
            return APIStatusError(error.response.status_code, str(error))
        case _:
            return ChatProviderError(f"Error: {error}")
```

**Anthropic 映射**：

```python
# src/kosong/contrib/chat_provider/anthropic.py
def _convert_error(error: AnthropicError) -> ChatProviderError:
    if isinstance(error, AnthropicAPIStatusError):
        return APIStatusError(error.status_code, str(error))
    if isinstance(error, AnthropicRateLimitError):
        return APIStatusError(getattr(error, "status_code", 429), str(error))
    if isinstance(error, AnthropicAPIConnectionError):
        return APIConnectionError(str(error))
    if isinstance(error, AnthropicAPITimeoutError):
        return APITimeoutError(str(error))
    return ChatProviderError(f"Anthropic error: {error}")
```

#### 8.4 Chaos 测试工具

```python
# src/kosong/chat_provider/chaos.py
class ChaosChatProvider:
    """Inject configurable failures for testing error handling."""

    error_probability: float = 0.3
    error_status_codes: list[int] = field(default_factory=lambda: [429, 500, 502, 503])
    retry_after: float | None = None  # 模拟 Rate Limit

    def _maybe_raise_error(self):
        if random.random() < self.error_probability:
            status = random.choice(self.error_status_codes)
            raise APIStatusError(status, f"Injected error: HTTP {status}")
```

---

### 9. republic (Python LLM Client Library)

republic 是一个 Python LLM 客户端库，采用**统一错误分类 + 多策略重试**的设计，特色是 ErrorKind 枚举驱动决策。

#### 9.1 ErrorKind 分类体系

```python
# src/republic/core/errors.py
class ErrorKind(StrEnum):
    """Stable error kinds for caller decisions."""
    INVALID_INPUT = "invalid_input"    # 400/404/413/422 - 请求错误
    CONFIG = "config"                   # 401/403 - 认证/配置错误
    PROVIDER = "provider"               # 5xx - 服务商错误
    TEMPORARY = "temporary"             # 429/408 - 可重试错误
    TOOL = "tool"                       # 工具执行错误
    NOT_FOUND = "not_found"
    UNKNOWN = "unknown"

@dataclass(frozen=True)
class RepublicError(Exception):
    """Public error type for Republic."""
    kind: ErrorKind
    message: str
    cause: Exception | None = None
```

#### 9.2 多层错误分类策略

republic 实现了**三层级**的错误分类器：

```python
# src/republic/core/execution.py
class ExecutionEngine:
    def classify_exception(self, exc: Exception) -> ErrorKind:
        # 1. 用户自定义分类器 (优先级最高)
        if self._error_classifier:
            kind = self._error_classifier(exc)
            if kind: return kind

        # 2. 第三方库异常映射 (any-llm)
        kind = self._classify_anyllm_exception(exc)
        if kind: return kind

        # 3. HTTP 状态码分类
        kind = self._classify_by_http_status(exc)
        if kind: return kind

        # 4. 文本签名匹配 (兜底)
        kind = self._classify_by_text_signature(exc)
        if kind: return kind

        return ErrorKind.UNKNOWN
```

**HTTP 状态码分类**：

```python
def _classify_by_http_status(self, exc: Exception) -> ErrorKind | None:
    status = self._extract_status_code(exc)  # 从多种属性提取
    if status in {401, 403}:
        return ErrorKind.CONFIG
    if status in {400, 404, 413, 422}:
        return ErrorKind.INVALID_INPUT
    if status in {408, 409, 425, 429}:
        return ErrorKind.TEMPORARY  # 可重试
    if status is not None and 500 <= status < 600:
        return ErrorKind.PROVIDER   # 服务商错误，可尝试 fallback
    return None
```

**文本签名匹配** (处理不规范的 provider)：

```python
def _classify_by_text_signature(self, exc: Exception) -> ErrorKind | None:
    name = type(exc).__name__.lower()
    msg = str(exc).lower()
    combined = f"{name} {msg}"

    if any(kw in combined for kw in ("auth", "unauthorized", "forbidden", "invalid api key")):
        return ErrorKind.CONFIG
    if any(kw in combined for kw in ("ratelimit", "rate limit", "too many requests", "429")):
        return ErrorKind.TEMPORARY
    if any(kw in combined for kw in ("timeout", "timed out", "connection error")):
        return ErrorKind.PROVIDER
    return None
```

#### 9.3 重试与 Fallback 决策

```python
# src/republic/core/execution.py
class AttemptDecision(Enum):
    RETRY_SAME_MODEL = auto()   # 同模型重试
    TRY_NEXT_MODEL = auto()     # 切换到 fallback 模型

def _handle_attempt_error(self, exc: Exception, provider_name: str,
                          model_id: str, attempt: int) -> AttemptOutcome:
    kind = self.classify_exception(exc)
    wrapped = self.wrap_error(exc, kind, provider_name, model_id)
    self.log_error(wrapped, provider_name, model_id, attempt)

    # 决策：是否可重试？
    can_retry = (
        kind in {ErrorKind.TEMPORARY, ErrorKind.PROVIDER} and
        attempt + 1 < self.max_attempts()
    )

    if can_retry:
        return AttemptOutcome(
            error=wrapped,
            decision=AttemptDecision.RETRY_SAME_MODEL
        )
    return AttemptOutcome(
        error=wrapped,
        decision=AttemptDecision.TRY_NEXT_MODEL
    )
```

#### 9.4 执行流程

```python
async def run_chat_async(self, messages: list[Message], ...) -> AsyncIterator[Event]:
    # 1. 生成候选模型列表 (primary + fallbacks)
    candidates = self.model_candidates(override_model, override_provider)

    for provider_name, model_id in candidates:
        for attempt in range(self.max_attempts()):
            try:
                client = self._get_client(provider_name)
                async for event in client.chat(...):
                    yield event
                return  # 成功

            except Exception as exc:
                outcome = self._handle_attempt_error(exc, provider_name, model_id, attempt)

                if outcome.decision == AttemptDecision.RETRY_SAME_MODEL:
                    await asyncio.sleep(self._backoff_delay(attempt))
                    continue  # 重试同一模型
                else:
                    break  # 尝试下一个 fallback

    # 所有候选都失败
    raise RepublicError(kind=ErrorKind.PROVIDER, message="All models failed")
```

#### 9.5 配置接口

```python
# src/republic/llm.py
class LLM:
    def __init__(
        self,
        model: str | None = None,
        *,
        max_retries: int = 3,              # 每个模型的最大重试次数
        fallback_models: list[str] | None = None,  # fallback 链
        error_classifier: Callable[[Exception], ErrorKind | None] | None = None,
        ...
    ):
```

---

## Comprehensive Comparison

### 错误分类策略对比

| 框架 | 分类方式 | 可恢复性标记 | 特色 |
|------|---------|-------------|------|
| **pydantic-ai** | 异常类层次 | `ModelRetry`, `CallDeferred` | 运行时错误细分，保留错误链 |
| **langchain** | 异常类 + ErrorCode | `send_to_llm` | 错误可修复性，标准化代码 |
| **pi-mono** | 状态标记 (`StopReason`) | `stopReason === "error"` | 流式友好，简化的状态机 |
| **kosong** | 异常类层次 | `RetryableChatProvider` 协议 | 协议驱动，调用方控制重试 |
| **republic** | `ErrorKind` 枚举 | `TEMPORARY`, `PROVIDER` | 分类驱动决策，多层分类器 |

### 重试机制对比

| 框架 | 重试层级 | 退避策略 | Retry-After 支持 | 最大延迟控制 |
|------|---------|---------|-----------------|-------------|
| **pydantic-ai** | HTTP 传输层 | `wait_retry_after` + exponential | 完整 (header + date) | `max_wait` 参数 |
| **langchain** | Runnable 链 | `wait_exponential_jitter` | tenacity 内置 | 配置参数 |
| **pi-mono** | Provider + Agent | exponential + server delay | 多种 header + 文本解析 | `maxRetryDelayMs` |
| **kosong** | 无 (调用方实现) | - | - | - |
| **republic** | 模型执行层 | exponential backoff | 间接 (via HTTP status) | - |

### Fallback 机制对比

| 框架 | Fallback 类型 | 异常传递 | 使用场景 |
|------|--------------|---------|---------|
| **pydantic-ai** | `FallbackModel` | 不支持 | 模型提供商故障 |
| **langchain** | `RunnableWithFallbacks` | `exception_key` | 任意 Runnable 失败 |
| **pi-mono** | Endpoint 列表 | 不支持 | 服务端点故障 |
| **kosong** | 无 | - | - |
| **republic** | `fallback_models` 列表 | 不支持 | 模型级故障切换 |

### 设计哲学总结

```
┌─────────────────┬─────────────────────────────────────────────────────────────┐
│ 框架            │ 设计哲学                                                     │
├─────────────────┼─────────────────────────────────────────────────────────────┤
│ pydantic-ai     │ 层次化错误类型 + 明确可恢复性标记，强调运行时行为的精确建模     │
│ langchain       │ 标准化错误代码 + 可修复性标记，强调与 LLM 的交互式错误恢复       │
│ pi-mono         │ 状态驱动 + 流式友好，强调跨边界的错误传播和用户体验              │
│ kosong          │ 协议驱动 + 责任分离，强调库的简洁性和调用方的控制权              │
│ republic        │ 分类驱动 + 策略模式，强调错误分类的准确性和恢复策略的灵活性      │
└─────────────────┴─────────────────────────────────────────────────────────────┘
```

---

## Related Files

### pydantic-ai
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/pydantic-ai/pydantic_ai_slim/pydantic_ai/exceptions.py` - 错误分类定义
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/pydantic-ai/pydantic_ai_slim/pydantic_ai/retries.py` - HTTP 传输层重试
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/pydantic-ai/pydantic_ai_slim/pydantic_ai/_agent_graph.py` - Agent 状态管理和重试逻辑
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/pydantic-ai/pydantic_ai_slim/pydantic_ai/models/fallback.py` - 模型级 Fallback
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/pydantic-ai/pydantic_ai_slim/pydantic_ai/models/openai.py` - 错误映射示例

### langchain
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/langchain/libs/core/langchain_core/exceptions.py` - 基础异常定义
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/langchain/libs/core/langchain_core/runnables/retry.py` - RunnableRetry 实现
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/langchain/libs/core/langchain_core/runnables/fallbacks.py` - RunnableWithFallbacks 实现
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/langchain/libs/core/langchain_core/callbacks/base.py` - 错误回调接口
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/langchain/libs/core/langchain_core/language_models/chat_models.py` - 错误响应生成

### pi-mono
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/pi-mono/packages/ai/src/types.ts` - 核心类型定义 (`StopReason`, `AssistantMessage`)
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/pi-mono/packages/ai/src/providers/google-gemini-cli.ts` - 重试逻辑和延迟提取
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/pi-mono/packages/ai/src/utils/overflow.ts` - 上下文溢出检测模式
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/pi-mono/packages/coding-agent/src/core/agent-session.ts` - Agent 自动重试逻辑

### kosong
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/kimi-cli/packages/kosong/src/kosong/chat_provider/__init__.py` - 错误类型和 `RetryableChatProvider` 协议
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/kimi-cli/packages/kosong/src/kosong/chat_provider/openai_common.py` - OpenAI 错误转换
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/kimi-cli/packages/kosong/src/kosong/tooling/error.py` - Tool 相关错误类型

### republic
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/republic/src/republic/core/errors.py` - `ErrorKind` 和 `RepublicError`
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/republic/src/republic/core/execution.py` - 重试逻辑和错误分类器
- `/Users/dylan/DylanLi/repo/agent-group/infra-LLM/republic/src/republic/llm.py` - 主 `LLM` 类配置

---
*Last updated: 2026-02-26*
