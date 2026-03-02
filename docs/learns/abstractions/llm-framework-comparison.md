# LLM Agent 框架对比分析

> **Related topics**: [[republic-architecture]], [[pydantic-ai-patterns]], [[litai-design]], [[kimi-cli-structure]]

## Overview

本文对比分析四个 Python LLM/Agent 框架的设计理念与实现差异：
- **LitAI** - Lightning AI 的 LLM router + minimal agent framework
- **Pydantic AI** - Pydantic 官方的 GenAI agent framework
- **Republic** - Tape-first LLM client (derived from LitAI)
- **Kimi CLI** - Moonshot AI 的终端 AI agent

---

## 1. LLM/VLM 输入输出处理

### LitAI: 统一路由 + 后台加载
```python
# 核心: 后台线程预加载模型，同步/异步统一接口
class LLM:
    def __init__(self):
        threading.Thread(target=self._load_models, daemon=True).start()

    def chat(self, prompt, images=None, stream=False):
        self._wait_for_model()  # 等待后台加载
        # 支持 images 参数处理 VLM 输入
```

**特点**:
- 后台线程预加载模型缓存
- 统一的 `chat()` 方法处理文本和多模态
- `images` 参数支持 `List[str]` 或 `str`
- 返回 `str` 或 `Iterator[str]`（流式）

### Pydantic AI: 类型安全 + 结构化输出
```python
# 核心: 泛型 Agent[AgentDepsT, OutputDataT]
class AbstractAgent(Generic[AgentDepsT, OutputDataT]):
    def run(self, user_prompt: str | Sequence[UserContent]) -> AgentRunResult[OutputDataT]:
        # UserContent = str | ImageUrl | AudioUrl | VideoUrl | BinaryContent | DocumentUrl
```

**特点**:
- 强类型泛型系统 `Agent[AgentDepsT, OutputDataT]`
- `UserContent` 支持多种多模态类型（ImageUrl, AudioUrl, VideoUrl, BinaryContent, DocumentUrl）
- `output_type` 参数支持 Pydantic 模型进行结构化输出
- 消息历史使用 `ModelMessage` 类型化系统

### Republic: 结构化输出 + Tape 记录
```python
# 核心: 结构化结果 + 错误分类
@dataclass(frozen=True)
class ToolAutoResult:
    kind: Literal["text", "tools", "error"]
    text: str | None
    tool_calls: list[dict[str, Any]]
    tool_results: list[Any]
    error: ErrorPayload | None
```

**特点**:
- `StructuredOutput` 返回类型，始终包含 error 信息
- `ErrorKind` 枚举分类所有错误类型
- `TapeEntry` 记录所有输入输出
- `TapeContext` 支持上下文窗口管理

### Kimi CLI: 运行时组合 + MCP 协议
```python
# 核心: Runtime 组合多个组件
@dataclass(slots=True, kw_only=True)
class Runtime:
    config: Config
    oauth: OAuthManager
    llm: LLM | None
    session: Session
    builtin_args: BuiltinSystemPromptArgs
    denwa_renji: DenwaRenji
    approval: Approval
    labor_market: LaborMarket
```

**特点**:
- `Runtime` dataclass 组合所有运行时依赖
- `BuiltinSystemPromptArgs` 注入系统变量（时间、工作目录等）
- 支持 MCP (Model Context Protocol) 工具
- Jinja2 模板渲染系统提示

---

## 2. Tool Trigger 和 Callback 机制

### LitAI: 装饰器 + 手动/自动模式
```python
@tool
def get_weather(location: str):
    return f"The weather in {location} is sunny"

# 方式 A: 自动执行
result = llm.chat("What's the weather?", tools=[get_weather], auto_call_tools=True)

# 方式 B: 手动控制
chosen_tool = llm.chat("What's the weather?", tools=[get_weather])
result = llm.call_tool(chosen_tool, tools=[get_weather])
```

**设计哲学**: "Zero magic, just plain Python"
- `@tool` 装饰器转换函数
- `LitTool` 基类支持有状态工具
- `auto_call_tools=False` 默认手动控制

### Pydantic AI: 依赖注入 + 装饰器注册
```python
class SupportDependencies:
    customer_id: int
    db: DatabaseConn

support_agent = Agent(deps_type=SupportDependencies, output_type=SupportOutput)

@support_agent.tool
async def customer_balance(ctx: RunContext[SupportDependencies], include_pending: bool) -> float:
    return await ctx.deps.db.customer_balance(id=ctx.deps.customer_id)
```

**设计哲学**: "FastAPI feeling"
- `RunContext` 泛型携带依赖
- `@agent.tool` 装饰器注册工具
- `ToolManager` 管理验证和执行
- 支持 `parallel_execution_mode` (parallel/sequential)
- Human-in-the-loop approval: `requires_approval`

### Republic: ToolExecutor + ToolContext
```python
class ToolExecutor:
    def execute(self, response, tools, *, context: ToolContext | None) -> ToolExecution:
        for tool_response in tool_calls:
            result = self._handle_tool_response(tool_response, tool_map, context)
```

**设计哲学**: "Tools without magic"
- `ToolContext` 传递上下文信息
- `ToolSet` 区分 runnable 和 non-runnable 工具
- 三种模式: `tool_calls()` / `run_tools()` / `stream_events()`
- `ToolCallAssembler` 处理流式工具调用增量

### Kimi CLI: Toolset + 依赖注入
```python
@dataclass(frozen=True, slots=True, kw_only=True)
class Agent:
    name: str
    system_prompt: str
    toolset: Toolset
    runtime: Runtime

# 工具加载
tool_deps = {
    KimiToolset: toolset,
    Runtime: runtime,
    Session: session,
    Approval: approval,
}
toolset.load_tools(tools, tool_deps)
```

**设计哲学**: "Production CLI agent"
- `KimiToolset` 封装工具加载
- `Approval` 系统处理危险操作确认
- `LaborMarket` 管理子 agent
- 支持 MCP server 工具

---

## 3. 多模型输出 Merge 策略

### LitAI: Fallback 链式尝试
```python
llm = LLM(
    model="openai/gpt-5",
    fallback_models=["google/gemini-2.5-flash", "anthropic/claude-3-5-sonnet"],
    max_retries=4,
)

# 同一对话使用不同模型
llm.chat("Is this a number?", model="google/gemini-2.5-flash", conversation="story")
llm.chat("Create a story about that number", conversation="story")  # 回到主模型
```

**特点**:
- `fallback_models` 链式降级
- `max_retries` 单模型重试
- 按请求切换模型
- 无内置 merge 策略，每个模型独立调用

### Pydantic AI: Fallback Model 包装
```python
# pydantic_ai/models/fallback.py
class FallbackModel:
    """尝试多个模型直到成功"""
```

**特点**:
- `FallbackModel` 作为模型包装器
- 验证失败会重试而非切换模型
- 结构化输出强制验证

### Republic: 同 LitAI 模式
```python
llm = LLM(
    model="openrouter:openrouter/free",
    fallback_models=fallback_models,
    max_retries=3,
)
```

**特点**:
- 继承 LitAI 的 fallback 机制
- `LLMCore` 统一处理重试逻辑

### Kimi CLI: 单一 LLM 实例
```python
@dataclass(slots=True, kw_only=True)
class Runtime:
    llm: LLM | None  # 单一 LLM 实例
```

**特点**:
- 运行时只持有一个 LLM 实例
- 通过 `LaborMarket` 管理子 agent 并行
- 无内置模型 merge

---

## 4. 独特设计模式和理念

### LitAI: Zero Magic Philosophy
```
✅ Use any AI model (OpenAI, etc.) ✅ Unified billing dashboard
✅ Auto retries and fallback        ✅ No MLOps glue code
✅ Tool use                          ✅ Start instantly
```

**核心模式**:
1. **Agentic if statement**: LLM 参与条件判断
2. **Background model loading**: 线程预加载提升响应
3. **Unified billing**: Lightning AI 统一计费

### Pydantic AI: Type-Safe Agent Framework
```
✅ Built by Pydantic Team   ✅ Model-agnostic
✅ Seamless Observability   ✅ Fully Type-safe
✅ Powerful Evals           ✅ MCP, A2A, and UI
```

**核心模式**:
1. **Graph-based execution**: `pydantic_graph` 支持复杂流程
2. **Durable execution**: 支持 Temporal/Prefect/DBOS
3. **Stream events**: `AgentStreamEvent` 完整事件流
4. **OpenTelemetry**: 内置可观测性

### Republic: Tape-First Architecture
```
✅ Plain Python             ✅ Structured Result
✅ Tools without magic      ✅ Tape-first memory
✅ Event streaming          ✅ Error classification
```

**核心模式**:
1. **Tape-first**: 所有交互记录为 `TapeEntry`
2. **ErrorKind**: 结构化错误分类
3. **Anchor/Handoff**: 上下文窗口管理
4. **Event streaming**: `StreamEvents` 完整事件流

### Kimi CLI: Terminal-First Agent
```
✅ Shell command mode       ✅ VS Code extension
✅ IDE integration (ACP)    ✅ Zsh integration
✅ MCP support              ✅ Skills system
```

**核心模式**:
1. **DenwaRenji**: 电话交接模式（子 agent 协作）
2. **LaborMarket**: 劳动力市场（动态/固定子 agent）
3. **Skills**: 技能发现和加载
4. **Approval**: 危险操作审批系统

---

## 5. Middleware 和 Streaming TTS 扩展性

### LitAI 扩展方案
```python
# 现有 streaming
for chunk in llm.chat("hello", stream=True):
    print(chunk, end="", flush=True)

# 添加 TTS Middleware 的可能方式
class TTSStreamingMiddleware:
    def __init__(self, tts_client):
        self.tts = tts_client

    def wrap_stream(self, stream):
        for chunk in stream:
            self.tts.speak_async(chunk)  # 异步 TTS
            yield chunk
```

**扩展点**:
- `stream=True` 返回 `Iterator[str]`
- 无内置 middleware 机制
- 需要包装返回的 iterator

### Pydantic AI 扩展方案
```python
# 现有 streaming events
async for event in agent.run_stream_events('Hello'):
    if isinstance(event, PartDeltaEvent):
        # 实时处理文本增量
        pass

# 添加 TTS Middleware
async def tts_event_handler(ctx: RunContext, events: AsyncIterable[AgentStreamEvent]):
    async for event in events:
        if isinstance(event, PartDeltaEvent) and isinstance(event.delta, TextPartDelta):
            await tts_client.speak(event.delta.content_delta)
        yield event

agent = Agent('openai:gpt-5.2', event_stream_handler=tts_event_handler)
```

**扩展点**:
- `event_stream_handler` 参数
- `run_stream_events()` 返回完整事件流
- `AgentStreamEvent` 包含 `PartStartEvent`, `PartDeltaEvent`, `PartEndEvent`
- 天然支持 middleware 模式

### Republic 扩展方案
```python
# 现有 streaming events
for event in llm.stream_events("Hello", tools=[...]):
    if event.kind == "text":
        print(event.data["delta"])

# 添加 TTS Middleware
class TTSStreamMiddleware:
    def __init__(self, tts_client):
        self.tts = tts_client

    def wrap(self, stream: StreamEvents) -> StreamEvents:
        def _iterator():
            for event in stream:
                if event.kind == "text":
                    self.tts.speak_async(event.data["delta"])
                yield event
        return StreamEvents(_iterator(), state=stream._state)
```

**扩展点**:
- `StreamEvents` 包装 iterator + state
- `StreamEvent` 包含 `kind` 和 `data`
- `StreamState` 携带 error 和 usage
- 可包装 iterator 实现中间件

### Kimi CLI 扩展方案
```python
# 现有: 通过 session.state 持久化
session.state.approval.yolo = True
session.save_state()

# 添加 TTS 需要修改 soul/agent.py 或添加工具
class TTSResult:
    def __init__(self, tts_client):
        self.tts = tts_client

    def process_chunk(self, chunk: str):
        self.tts.speak_async(chunk)
```

**扩展点**:
- `Session` 管理 state 持久化
- `DenwaRenji` 可扩展子 agent 通信
- 需要修改核心代码添加 streaming middleware

---

## 总结对比表

| 特性 | LitAI | Pydantic AI | Republic | Kimi CLI |
|------|-------|-------------|----------|----------|
| **类型系统** | 简单 | 强泛型 | dataclass | dataclass |
| **多模态** | images | 6种类型 | 继承 any-llm | 继承 |
| **Tool 注册** | @tool 装饰器 | @agent.tool | Tool 类 | Toolset |
| **依赖注入** | 无 | RunContext | ToolContext | Runtime |
| **流式事件** | 无 | AgentStreamEvent | StreamEvent | 无 |
| **错误处理** | Exception | Exception | ErrorKind | Exception |
| **历史记录** | conversation | ModelMessage[] | TapeEntry[] | Session.state |
| **Middleware** | 无 | event_stream_handler | 包装 StreamEvents | 无 |
| **TTS 扩展** | 包装 iterator | 天然支持 | 包装 iterator | 需修改核心 |

---

## 设计建议

### 如果添加 Middleware/Streaming TTS:

1. **Pydantic AI** - 最佳选择
   - `event_stream_handler` 天然支持
   - 完整的事件类型系统
   - 可在事件流中插入任何处理逻辑

2. **Republic** - 良好选择
   - `StreamEvents` 设计可扩展
   - `StreamState` 可携带中间件状态
   - 需要实现包装器模式

3. **LitAI** - 需要扩展
   - 无内置 middleware
   - 需要包装 `Iterator[str]`

4. **Kimi CLI** - 需要核心修改
   - 终端场景为主
   - TTS 需求可能通过工具实现

---

## 6. 底层 LLM 抽象层对比（核心通信层）

本节对比四个框架与 LLM 服务端通信的底层抽象层设计。

### 架构总览

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           LLM 抽象层架构对比                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│ LitAI        │  LLM → SDKLLM (lightning_sdk) → 统一 API 网关                 │
│ Republic     │  LLMCore → any-llm → 各 Provider SDK                          │
│ Pydantic AI  │  Model (ABC) → Provider → 各 Provider SDK                     │
│ Kimi CLI     │  LLM → kosong.ChatProvider (Protocol) → 各 Provider SDK       │
└─────────────────────────────────────────────────────────────────────────────┘
```

### LitAI: Lightning SDK 封装

**依赖**: `lightning_sdk.llm.LLM` (私有 SDK)

```python
# litai/llm.py
class LLM:
    _sdkllm_cache: Dict[str, SDKLLM] = {}

    def __init__(self, model, fallback_models, billing, max_retries, ...):
        self._llm: Optional[SDKLLM] = None
        # 后台线程预加载
        threading.Thread(target=self._load_models, daemon=True).start()

    def _load_models(self):
        # 缓存 SDKLLM 实例
        key = f"{self._model}::{self._teamspace}::{self._enable_async}"
        self._sdkllm_cache[key] = SDKLLM(name=self._model, teamspace=self._teamspace)

    def chat(self, prompt, ...):
        self._wait_for_model()  # 等待后台加载
        response = model.chat(  # 调用 SDKLLM.chat()
            prompt=prompt,
            system_prompt=system_prompt,
            images=images,
            conversation=conversation,
            tools=tools,
            ...
        )
```

**核心特点**:
- **私有 SDK**: 依赖 Lightning AI 的 `lightning_sdk` 包
- **后台加载**: `threading.Thread` 预加载模型，提升首次响应
- **统一网关**: 所有 API 请求通过 Lightning AI 统一计费
- **模型缓存**: `_sdkllm_cache` 类级别缓存，跨实例共享

**通信流程**:
```
LLM.chat() → SDKLLM.chat() → Lightning API Gateway → Provider API
```

---

### Republic: any-llm 统一接口

**依赖**: `any-llm` (开源统一 LLM 接口库)

```python
# republic/core/execution.py
from any_llm import AnyLLM
from any_llm.exceptions import (
    AuthenticationError, RateLimitError, ContextLengthExceededError, ...
)

class LLMCore:
    RETRY = object()  # 重试信号

    def __init__(self, provider, model, fallback_models, max_retries, api_key, api_base, ...):
        self._client_cache: dict[str, AnyLLM] = {}

    def get_client(self, provider: str) -> AnyLLM:
        cache_key = self._freeze_cache_key(provider, api_key, api_base)
        if cache_key not in self._client_cache:
            self._client_cache[cache_key] = AnyLLM.create(
                provider, api_key=api_key, api_base=api_base, **self._client_args
            )
        return self._client_cache[cache_key]

    def run_chat_sync(self, messages_payload, tools_payload, ...):
        for provider_name, model_id, client in self.iter_clients(model, provider):
            for attempt in range(self.max_attempts()):
                try:
                    response = client.completion(  # any-llm 统一接口
                        model=model_id,
                        messages=messages_payload,
                        tools=tools_payload,
                        stream=stream,
                        ...
                    )
                except Exception as exc:
                    outcome = self._handle_attempt_error(exc, provider_name, model_id, attempt)
                    if outcome.decision is AttemptDecision.RETRY_SAME_MODEL:
                        continue
                    break
```

**错误分类系统**:
```python
def classify_exception(self, exc: Exception) -> ErrorKind:
    # 1. 检查 any-llm 异常类型
    if isinstance(exc, (MissingApiKeyError, AuthenticationError)):
        return ErrorKind.CONFIG
    if isinstance(exc, (RateLimitError, ContentFilterError)):
        return ErrorKind.TEMPORARY
    if isinstance(exc, (ContextLengthExceededError, ModelNotFoundError)):
        return ErrorKind.INVALID_INPUT

    # 2. 检查 HTTP 状态码
    status = self._extract_status_code(exc)
    if status in {401, 403}: return ErrorKind.CONFIG
    if status in {429}: return ErrorKind.TEMPORARY
    if status in {500, 502, 503}: return ErrorKind.PROVIDER

    # 3. 文本模式匹配
    if re.search(r"ratelimit|rate.limit", str(exc)):
        return ErrorKind.TEMPORARY
```

**核心特点**:
- **any-llm 抽象**: 使用开源统一接口库
- **三层错误分类**: 类型 → HTTP 状态码 → 文本模式
- **Provider 前缀**: `provider:model` 格式 (如 `openai:gpt-5`)
- **Fallback 链**: 支持 `fallback_models` 自动降级

**通信流程**:
```
LLMCore.run_chat_sync() → AnyLLM.completion() → Provider SDK → Provider API
```

---

### Pydantic AI: 自建 Model 抽象

**依赖**: 直接使用各 Provider SDK (openai, anthropic, google-genai, ...)

```python
# pydantic_ai/models/__init__.py
class Model(ABC):
    """Abstract class for a model."""

    @abstractmethod
    async def request(
        self,
        messages: list[ModelMessage],
        model_settings: ModelSettings | None,
        model_request_parameters: ModelRequestParameters,
    ) -> ModelResponse:
        """Make a request to the model."""
        raise NotImplementedError()

    @asynccontextmanager
    async def request_stream(
        self,
        messages: list[ModelMessage],
        model_settings: ModelSettings | None,
        model_request_parameters: ModelRequestParameters,
    ) -> AsyncIterator[StreamedResponse]:
        """Make a request to the model and return a streaming response."""
        raise NotImplementedError()

# pydantic_ai/models/openai.py
class OpenAIChatModel(Model):
    def __init__(self, model_name: str, *, provider: Provider[AsyncOpenAI] | None = None):
        self.model_name = model_name
        self.client = provider.client if provider else AsyncOpenAI()

    async def request(self, messages, model_settings, model_request_parameters) -> ModelResponse:
        # 直接调用 OpenAI SDK
        response = await self.client.chat.completions.create(
            model=self.model_name,
            messages=await self._messages_to_openai(messages),
            tools=self._tools_to_openai(tools),
            ...
        )
        return self._response_to_model_response(response)

# pydantic_ai/models/anthropic.py
class AnthropicModel(Model):
    def __init__(self, model_name: str, *, provider: Provider[AsyncAnthropic] | None = None):
        self.client = provider.client if provider else AsyncAnthropic()

    async def request(self, messages, ...) -> ModelResponse:
        # 直接调用 Anthropic SDK
        response = await self.client.beta.messages.create(...)
```

**Provider 推断**:
```python
def infer_model(model: Model | KnownModelName | str) -> Model:
    if isinstance(model, Model):
        return model

    provider_name, model_name = model.split(':', maxsplit=1)
    provider = provider_factory(provider_name)

    if provider_name == 'openai':
        return OpenAIChatModel(model_name, provider=provider)
    elif provider_name == 'anthropic':
        return AnthropicModel(model_name, provider=provider)
    elif provider_name == 'google-gla':
        return GoogleModel(model_name, provider=provider)
    # ... 20+ providers
```

**核心特点**:
- **自建抽象**: 不依赖第三方统一库，直接调用各 Provider SDK
- **ABC 模式**: `Model` 抽象类定义统一接口
- **Provider 工厂**: `infer_provider()` 根据名称创建 Provider
- **Profile 系统**: `ModelProfile` 定义模型能力（输出模式、工具支持等）
- **Settings 合并**: `merge_model_settings()` 支持多层配置

**通信流程**:
```
Agent.run() → Model.request() → Provider SDK (openai/anthropic/...) → Provider API
```

---

### Kimi CLI (kosong): Protocol 抽象

**依赖**: 内置 `kosong` 库 + 各 Provider SDK

```python
# kosong/chat_provider/__init__.py
@runtime_checkable
class ChatProvider(Protocol):
    """The interface of chat providers."""

    name: str
    model_name: str
    thinking_effort: ThinkingEffort | None

    async def generate(
        self,
        system_prompt: str,
        tools: Sequence[Tool],
        history: Sequence[Message],
    ) -> "StreamedMessage":
        """Generate a new message."""
        ...

    def with_thinking(self, effort: ThinkingEffort) -> Self:
        """Return a copy configured with thinking effort."""
        ...

@runtime_checkable
class StreamedMessage(Protocol):
    """The interface of streamed messages."""

    def __aiter__(self) -> AsyncIterator[StreamedMessagePart]:
        ...

    @property
    def id(self) -> str | None: ...
    @property
    def usage(self) -> TokenUsage | None: ...

# kosong/chat_provider/kimi.py
class Kimi:
    """A chat provider that uses the Kimi API."""

    name = "kimi"

    def __init__(self, model: str, api_key: str, base_url: str, ...):
        self.client: AsyncOpenAI = create_openai_client(api_key, base_url, ...)

    async def generate(self, system_prompt, tools, history) -> StreamedMessage:
        # 使用 OpenAI SDK (Kimi 兼容 OpenAI API)
        stream = await self.client.chat.completions.create(
            model=self.model,
            messages=messages,
            tools=tools,
            stream=True,
            ...
        )
        return _KimiStreamedMessage(stream)

# kosong/contrib/chat_provider/anthropic.py
class Anthropic:
    """Anthropic chat provider using native SDK."""

    async def generate(self, system_prompt, tools, history) -> StreamedMessage:
        # 使用 Anthropic SDK
        stream = await self.client.messages.create(...)
        return _AnthropicStreamedMessage(stream)
```

**错误定义**:
```python
class ChatProviderError(Exception): ...
class APIConnectionError(ChatProviderError): ...
class APITimeoutError(ChatProviderError): ...
class APIStatusError(ChatProviderError):
    status_code: int
class APIEmptyResponseError(ChatProviderError): ...
```

**核心特点**:
- **Protocol 模式**: 使用 `@runtime_checkable` Protocol 定义接口
- **Provider 隔离**: 每个 Provider 独立实现，不共享代码
- **OpenAI 兼容**: Kimi 使用 OpenAI SDK (API 兼容)
- **流式优先**: `StreamedMessage` 作为核心返回类型
- **Thinking 支持**: `with_thinking()` 方法配置思考模式

**通信流程**:
```
LLM.chat_provider.generate() → ChatProvider.generate() → Provider SDK → Provider API
```

---

### 底层抽象层对比表

| 特性 | LitAI | Republic | Pydantic AI | Kimi CLI (kosong) |
|------|-------|----------|-------------|-------------------|
| **底层依赖** | lightning_sdk (私有) | any-llm (开源) | 各 Provider SDK | 各 Provider SDK |
| **抽象模式** | 类封装 | 类封装 | ABC 抽象类 | Protocol |
| **Provider 数量** | 统一网关 | 20+ | 20+ | 5 (kimi, openai, anthropic, gemini, vertexai) |
| **错误分类** | 简单 | ErrorKind 枚举 | Exception | ChatProviderError 层级 |
| **客户端缓存** | 类级别 `_sdkllm_cache` | 实例级别 `_client_cache` | 无 (每次创建) | 无 |
| **后台加载** | ✅ threading | ❌ | ❌ | ❌ |
| **统一计费** | ✅ Lightning AI | ❌ | ❌ | ❌ |
| **流式返回** | `Iterator[str]` | `StreamEvents` | `StreamedResponse` | `StreamedMessage` |
| **Token 用量** | 从 response 解析 | `StreamState.usage` | `RequestUsage` | `TokenUsage` |

---

### 设计决策对比

#### 1. 为什么选择不同的抽象层？

| 框架 | 设计决策 | 理由 |
|------|----------|------|
| **LitAI** | 私有 SDK + 统一网关 | 商业产品，需要统一计费和管理 |
| **Republic** | any-llm | 开源项目，需要最大化 Provider 兼容性 |
| **Pydantic AI** | 自建抽象 | 完全控制，支持 Provider 特性差异化 |
| **Kimi CLI** | Protocol | 灵活扩展，支持 Kimi 特有功能 (thinking) |

#### 2. 错误处理策略

| 框架 | 策略 | 优点 | 缺点 |
|------|------|------|------|
| **LitAI** | 简单 Exception | 简单直接 | 无分类，难以精确处理 |
| **Republic** | ErrorKind 枚举 | 结构化分类，支持智能重试 | 复杂度高 |
| **Pydantic AI** | Exception 子类 | 标准化，IDE 友好 | 无统一分类 |
| **Kimi CLI** | ChatProviderError 层级 | 清晰层级，Provider 隔离 | 需要转换 |

#### 3. Provider 扩展性

**Pydantic AI** (最灵活):
```python
# 添加新 Provider
class MyProviderModel(Model):
    async def request(self, messages, ...) -> ModelResponse:
        response = await my_sdk.generate(...)
        return self._convert(response)

# 注册到 infer_model()
elif provider_name == 'myprovider':
    return MyProviderModel(model_name, provider=provider)
```

**kosong** (最解耦):
```python
# 添加新 Provider - 只需实现 Protocol
class MyChatProvider:
    name = "myprovider"

    async def generate(self, system_prompt, tools, history) -> StreamedMessage:
        ...

# 无需修改核心代码，直接使用
chat_provider = MyChatProvider(model="my-model")
```

---

### 选择建议

| 场景 | 推荐框架 | 理由 |
|------|----------|------|
| **商业产品，需要统一计费** | LitAI | Lightning AI 网关 |
| **开源项目，最大化兼容** | Republic | any-llm 支持 20+ Provider |
| **企业级，需要完全控制** | Pydantic AI | 自建抽象，支持 Provider 特性 |
| **终端应用，快速迭代** | Kimi CLI (kosong) | Protocol 灵活，易于扩展 |

---

*Last updated: 2026-02-25*
