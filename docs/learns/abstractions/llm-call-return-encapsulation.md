# LLM Call 和 Return 封装机制对比

> **Related topics**: [[llm-framework-comparison]], [[llm-abstraction-comparison]]

## Overview

本文对比分析四个框架如何封装 LLM API 的 **Call（请求）** 和 **Return（响应）**，以及它们是否使用各 Provider 的官方 SDK。

---

## 1. SDK 使用策略对比

| 框架 | SDK 策略 | 使用的 SDK |
|------|----------|-----------|
| **LitAI** | 私有统一 SDK | `lightning_sdk.llm.LLM` (Lightning AI 私有) |
| **Republic** | 第三方统一库 | `any-llm` (开源统一接口) |
| **Pydantic AI** | 各 Provider 官方 SDK | `openai`, `anthropic`, `google-genai`, `mistralai`, ... |
| **Kimi CLI (kosong)** | 各 Provider 官方 SDK | `openai`, `anthropic`, `google-genai` |

---

## 2. LitAI: Lightning SDK 统一封装

### SDK 依赖

```python
# litai/llm.py
from lightning_sdk.llm import LLM as SDKLLM
from lightning_sdk.lightning_cloud.openapi import V1ConversationResponseChunk
```

**特点**: 完全依赖 Lightning AI 私有 SDK，不直接使用任何 Provider SDK。

### Call 封装

```python
class LLM:
    _sdkllm_cache: Dict[str, SDKLLM] = {}  # 类级别缓存

    def __init__(self, model, fallback_models, billing, max_retries, ...):
        self._llm: Optional[SDKLLM] = None
        # 后台线程预加载
        threading.Thread(target=self._load_models, daemon=True).start()

    def _load_models(self):
        # 缓存 SDKLLM 实例
        key = f"{self._model}::{self._teamspace}::{self._enable_async}"
        if key not in self._sdkllm_cache:
            self._sdkllm_cache[key] = SDKLLM(
                name=self._model,
                teamspace=self._teamspace,
                enable_async=self._enable_async
            )
        self._llm = self._sdkllm_cache[key]

    def _model_call(self, model: SDKLLM, prompt, ...):
        # 直接调用 SDKLLM.chat()
        response = model.chat(
            prompt=prompt,
            system_prompt=system_prompt,
            max_completion_tokens=max_completion_tokens,
            images=images,
            conversation=conversation,
            metadata=metadata,
            stream=stream,
            full_response=full_response,
            tools=tools,
            reasoning_effort=reasoning_effort,
            **kwargs,
        )
        return response
```

### Return 封装

```python
@staticmethod
def _format_tool_response(
    response: V1ConversationResponseChunk,  # Lightning SDK 类型
    call_tools: bool = True,
    lit_tools: Optional[List[LitTool]] = None
) -> str:
    if response.choices is None or len(response.choices) == 0:
        return ""

    tool_calls = response.choices[0].tool_calls
    result = []
    for tool_call in tool_calls:
        new_tool = {
            "function": {
                "arguments": tool_call.function.arguments,
                "name": tool_call.function.name,
            }
        }
        result.append(new_tool)
    return json.dumps(result)
```

### 通信流程

```
LLM.chat()
  ↓
SDKLLM.chat()  [lightning_sdk]
  ↓
Lightning API Gateway  [统一网关]
  ↓
Provider API (OpenAI/Anthropic/Google/...)
```

**核心特点**:
- 所有请求通过 Lightning AI 网关
- 统一计费和管理
- 后台线程预加载模型
- 类级别缓存 SDKLLM 实例

---

## 3. Republic: any-llm 统一接口

### SDK 依赖

```python
# republic/core/execution.py
from any_llm import AnyLLM
from any_llm.exceptions import (
    AuthenticationError,
    RateLimitError,
    ContextLengthExceededError,
    ModelNotFoundError,
    ProviderError,
    ...
)
```

**特点**: 使用开源的 `any-llm` 库，它内部封装了各 Provider SDK。

### Call 封装

```python
class LLMCore:
    RETRY = object()  # 重试信号

    def __init__(self, provider, model, fallback_models, max_retries, api_key, api_base, ...):
        self._client_cache: dict[str, AnyLLM] = {}

    def get_client(self, provider: str) -> AnyLLM:
        """获取或创建 AnyLLM 客户端"""
        cache_key = self._freeze_cache_key(provider, api_key, api_base)
        if cache_key not in self._client_cache:
            self._client_cache[cache_key] = AnyLLM.create(
                provider,
                api_key=api_key,
                api_base=api_base,
                **self._client_args
            )
        return self._client_cache[cache_key]

    def run_chat_sync(self, messages_payload, tools_payload, ...):
        """执行同步聊天请求"""
        for provider_name, model_id, client in self.iter_clients(model, provider):
            for attempt in range(self.max_attempts()):
                try:
                    response = client.completion(  # any-llm 统一接口
                        model=model_id,
                        messages=messages_payload,
                        tools=tools_payload,
                        stream=stream,
                        reasoning_effort=reasoning_effort,
                        **self._decide_kwargs_for_provider(provider_name, max_tokens, kwargs),
                    )
                except Exception as exc:
                    outcome = self._handle_attempt_error(exc, provider_name, model_id, attempt)
                    if outcome.decision is AttemptDecision.RETRY_SAME_MODEL:
                        continue
                    break
                else:
                    result = on_response(response, provider_name, model_id, attempt)
                    if result is self.RETRY:
                        continue
                    return result
```

### Return 封装

```python
# republic/clients/chat.py
class ChatClient:
    @staticmethod
    def _extract_text(response: Any) -> str:
        """从 any-llm 响应中提取文本"""
        if isinstance(response, str):
            return response
        choices = getattr(response, "choices", None)
        if not choices:
            return ""
        message = getattr(choices[0], "message", None)
        if message is None:
            return ""
        return getattr(message, "content", "") or ""

    @staticmethod
    def _extract_tool_calls(response: Any) -> list[dict[str, Any]]:
        """从 any-llm 响应中提取工具调用"""
        choices = getattr(response, "choices", None)
        if not choices:
            return []
        message = getattr(choices[0], "message", None)
        if message is None:
            return []
        tool_calls = getattr(message, "tool_calls", None) or []
        calls: list[dict[str, Any]] = []
        for tool_call in tool_calls:
            entry: dict[str, Any] = {
                "function": {
                    "name": tool_call.function.name,
                    "arguments": tool_call.function.arguments,
                }
            }
            call_id = getattr(tool_call, "id", None)
            if call_id:
                entry["id"] = call_id
            calls.append(entry)
        return calls

    @staticmethod
    def _extract_usage(response: Any) -> dict[str, Any] | None:
        """从 any-llm 响应中提取 usage"""
        usage = getattr(response, "usage", None)
        if usage is None:
            return None
        if hasattr(usage, "model_dump"):
            return usage.model_dump()
        # ...
```

### 流式响应处理

```python
class ToolCallAssembler:
    """流式工具调用增量合并器"""

    def __init__(self):
        self._calls: dict[object, dict[str, Any]] = {}
        self._order: list[object] = []
        self._index_to_key: dict[Any, object] = {}

    def add_deltas(self, tool_calls: list[Any]):
        """添加工具调用增量"""
        for position, tool_call in enumerate(tool_calls):
            key = self._resolve_key(tool_call, position)
            if key not in self._calls:
                self._order.append(key)
                self._calls[key] = {"function": {"name": "", "arguments": ""}}
            entry = self._calls[key]
            # 合并增量
            func = getattr(tool_call, "function", None)
            if func:
                name = getattr(func, "name", None)
                if name:
                    entry["function"]["name"] = name
                arguments = getattr(func, "arguments", None)
                if arguments:
                    entry["function"]["arguments"] = entry["function"].get("arguments", "") + arguments

    def finalize(self) -> list[dict[str, Any]]:
        return [self._calls[key] for key in self._order]
```

### 通信流程

```
ChatClient.chat()
  ↓
LLMCore.run_chat_sync()
  ↓
AnyLLM.completion()  [any-llm 统一接口]
  ↓
Provider SDK (openai/anthropic/...)  [any-llm 内部调用]
  ↓
Provider API
```

**核心特点**:
- 使用 `any-llm` 作为统一接口层
- 三层错误分类：SDK 类型 → HTTP 状态码 → 文本模式
- `ToolCallAssembler` 处理流式工具调用增量
- 客户端缓存（实例级别）

---

## 4. Pydantic AI: 直接使用各 Provider SDK

### SDK 依赖

```python
# pydantic_ai/models/openai.py
from openai import AsyncOpenAI, AsyncStream, NOT_GIVEN

# pydantic_ai/models/anthropic.py
from anthropic import AsyncAnthropic, AsyncAnthropicBedrock, AsyncStream

# pydantic_ai/models/google.py
from google.genai import Client as GoogleClient
```

**特点**: 每个 Provider 都有独立的 Model 实现，直接使用官方 SDK。

### Provider 抽象

```python
# pydantic_ai/providers/__init__.py
class Provider(ABC, Generic[InterfaceClient]):
    """Provider 抽象类 - 负责提供认证客户端"""

    _client: InterfaceClient

    @property
    @abstractmethod
    def name(self) -> str:
        """Provider 名称"""
        raise NotImplementedError()

    @property
    @abstractmethod
    def base_url(self) -> str:
        """Provider API 基础 URL"""
        raise NotImplementedError()

    @property
    @abstractmethod
    def client(self) -> InterfaceClient:
        """Provider 客户端"""
        raise NotImplementedError()

# pydantic_ai/providers/openai.py
class OpenAIProvider(Provider[AsyncOpenAI]):
    """OpenAI Provider"""

    @property
    def name(self) -> str:
        return 'openai'

    @property
    def client(self) -> AsyncOpenAI:
        return self._client

    def __init__(self, base_url=None, api_key=None, openai_client=None, http_client=None):
        if openai_client is not None:
            self._client = openai_client
        else:
            http_client = cached_async_http_client(provider='openai')
            self._client = AsyncOpenAI(base_url=base_url, api_key=api_key, http_client=http_client)
```

### Call 封装 (OpenAI)

```python
# pydantic_ai/models/openai.py
class OpenAIChatModel(Model):
    """OpenAI Chat Model - 直接使用 openai SDK"""

    def __init__(self, model_name: str, *, provider: Provider[AsyncOpenAI] | None = None):
        self.model_name = model_name
        self.client = provider.client if provider else AsyncOpenAI()

    async def request(
        self,
        messages: list[ModelMessage],
        model_settings: ModelSettings | None,
        model_request_parameters: ModelRequestParameters,
    ) -> ModelResponse:
        # 准备请求
        model_settings, params = self.prepare_request(model_settings, model_request_parameters)

        # 直接调用 OpenAI SDK
        response = await self.client.chat.completions.create(
            model=self.model_name,
            messages=await self._messages_to_openai(messages),
            tools=self._tools_to_openai(params.function_tools) if params.function_tools else NOT_GIVEN,
            tool_choice=self._tool_choice(params),
            **self._get_kwargs(model_settings),
        )
        return self._response_to_model_response(response)

    @asynccontextmanager
    async def request_stream(self, messages, model_settings, model_request_parameters):
        """流式请求"""
        response = await self.client.chat.completions.create(
            model=self.model_name,
            messages=await self._messages_to_openai(messages),
            stream=True,
            stream_options={"include_usage": True},
            ...
        )
        yield OpenAIStreamedResponse(response, model_request_parameters)
```

### Call 封装 (Anthropic)

```python
# pydantic_ai/models/anthropic.py
class AnthropicModel(Model):
    """Anthropic Model - 直接使用 anthropic SDK"""

    def __init__(self, model_name: str, *, provider: Provider[AsyncAnthropic] | None = None):
        self.client = provider.client if provider else AsyncAnthropic()

    async def request(self, messages, model_settings, model_request_parameters) -> ModelResponse:
        # 直接调用 Anthropic SDK
        response = await self.client.beta.messages.create(
            model=self.model_name,
            messages=await self._messages_to_anthropic(messages),
            tools=self._tools_to_anthropic(params.function_tools),
            system=instructions,
            max_tokens=max_tokens,
            ...
        )
        return self._response_to_model_response(response)
```

### Return 封装

```python
# pydantic_ai/models/openai.py
class OpenAIStreamedResponse(StreamedResponse):
    """OpenAI 流式响应处理"""

    def __init__(self, response: AsyncStream[ChatCompletionChunk], ...):
        self._response = response

    async def _get_event_iterator(self) -> AsyncIterator[ModelResponseStreamEvent]:
        """将 OpenAI 流式响应转换为 Pydantic AI 事件"""
        async for chunk in self._response:
            # 处理 usage
            if chunk.usage:
                self._usage = self._extract_usage(chunk.usage)

            for choice in chunk.choices:
                delta = choice.delta

                # 文本增量
                if delta.content:
                    yield PartDeltaEvent(
                        index=choice.index,
                        delta=TextPartDelta(content_delta=delta.content),
                    )

                # 工具调用增量
                if delta.tool_calls:
                    for tool_call in delta.tool_calls:
                        if tool_call.function:
                            yield PartDeltaEvent(
                                index=tool_call.index,
                                delta=ToolCallPartDelta(
                                    tool_name=tool_call.function.name,
                                    arguments_json_delta=tool_call.function.arguments,
                                ),
                            )
```

### 通信流程

```
Agent.run()
  ↓
Model.request()  [ABC 抽象方法]
  ↓
OpenAIChatModel.request()
  ↓
AsyncOpenAI.chat.completions.create()  [openai 官方 SDK]
  ↓
OpenAI API

# 或

AnthropicModel.request()
  ↓
AsyncAnthropic.beta.messages.create()  [anthropic 官方 SDK]
  ↓
Anthropic API
```

**核心特点**:
- 每个 Provider 独立实现 Model 子类
- 直接使用官方 SDK，无中间层
- Provider 抽象负责客户端管理
- Profile 系统定义模型能力

---

## 5. Kimi CLI (kosong): Protocol 抽象 + 官方 SDK

### SDK 依赖

```python
# kosong/chat_provider/kimi.py
from openai import AsyncOpenAI, AsyncStream

# kosong/contrib/chat_provider/anthropic.py
from anthropic import AsyncAnthropic

# kosong/contrib/chat_provider/google_genai.py
from google.genai import Client as GoogleClient
```

**特点**: Protocol 定义接口，各 Provider 独立实现，直接使用官方 SDK。

### Protocol 定义

```python
# kosong/chat_provider/__init__.py
@runtime_checkable
class ChatProvider(Protocol):
    """Chat Provider 接口"""

    name: str
    model_name: str
    thinking_effort: ThinkingEffort | None

    async def generate(
        self,
        system_prompt: str,
        tools: Sequence[Tool],
        history: Sequence[Message],
    ) -> "StreamedMessage":
        """生成消息"""
        ...

    def with_thinking(self, effort: ThinkingEffort) -> Self:
        """配置思考模式"""
        ...

@runtime_checkable
class StreamedMessage(Protocol):
    """流式消息接口"""

    def __aiter__(self) -> AsyncIterator[StreamedMessagePart]:
        ...

    @property
    def id(self) -> str | None: ...

    @property
    def usage(self) -> TokenUsage | None: ...
```

### Call 封装 (Kimi/OpenAI 兼容)

```python
# kosong/chat_provider/kimi.py
class Kimi:
    """Kimi Chat Provider - 使用 OpenAI SDK (API 兼容)"""

    name = "kimi"

    def __init__(self, model: str, api_key: str, base_url: str, ...):
        self.client: AsyncOpenAI = create_openai_client(api_key, base_url, ...)

    async def generate(
        self,
        system_prompt: str,
        tools: Sequence[Tool],
        history: Sequence[Message],
    ) -> "OpenAILegacyStreamedMessage":
        # 转换消息格式
        messages: list[ChatCompletionMessageParam] = []
        if system_prompt:
            messages.append({"role": "system", "content": system_prompt})
        messages.extend(self._convert_message(message) for message in history)

        # 直接调用 OpenAI SDK
        response = await self.client.chat.completions.create(
            model=self.model,
            messages=messages,
            tools=(tool_to_openai(tool) for tool in tools),
            stream=self.stream,
            stream_options={"include_usage": True} if self.stream else omit,
            reasoning_effort=self._reasoning_effort,
            **generation_kwargs,
        )
        return OpenAILegacyStreamedMessage(response, self._reasoning_key)
```

### Call 封装 (Anthropic)

```python
# kosong/contrib/chat_provider/anthropic.py
class Anthropic:
    """Anthropic Chat Provider - 使用 Anthropic SDK"""

    async def generate(
        self,
        system_prompt: str,
        tools: Sequence[Tool],
        history: Sequence[Message],
    ) -> "AnthropicStreamedMessage":
        # 转换消息格式
        messages = self._convert_messages(history)

        # 直接调用 Anthropic SDK
        response = await self.client.messages.create(
            model=self.model,
            messages=messages,
            system=system_prompt,
            tools=self._convert_tools(tools),
            max_tokens=self._default_max_tokens,
            stream=True,
            ...
        )
        return AnthropicStreamedMessage(response)
```

### Return 封装

```python
# kosong/contrib/chat_provider/openai_legacy.py
class OpenAILegacyStreamedMessage:
    """OpenAI 流式消息 - 实现 StreamedMessage Protocol"""

    def __init__(self, response: ChatCompletion | AsyncStream[ChatCompletionChunk], reasoning_key: str | None):
        if isinstance(response, ChatCompletion):
            self._iter = self._convert_non_stream_response(response)
        else:
            self._iter = self._convert_stream_response(response)
        self._id: str | None = None
        self._usage: CompletionUsage | None = None

    def __aiter__(self) -> AsyncIterator[StreamedMessagePart]:
        return self

    async def __anext__(self) -> StreamedMessagePart:
        return await self._iter.__anext__()

    @property
    def id(self) -> str | None:
        return self._id

    @property
    def usage(self) -> TokenUsage | None:
        if self._usage:
            cached = 0
            other_input = self._usage.prompt_tokens
            if self._usage.prompt_tokens_details?.cached_tokens:
                cached = self._usage.prompt_tokens_details.cached_tokens
                other_input -= cached
            return TokenUsage(
                input_other=other_input,
                output=self._usage.completion_tokens,
                input_cache_read=cached,
            )
        return None

    async def _convert_stream_response(
        self,
        response: AsyncIterator[ChatCompletionChunk],
    ) -> AsyncIterator[StreamedMessagePart]:
        async for chunk in response:
            if chunk.id:
                self._id = chunk.id
            if chunk.usage:
                self._usage = chunk.usage

            if not chunk.choices:
                continue

            delta = chunk.choices[0].delta

            # 转换思考内容
            if self._reasoning_key and (reasoning_content := getattr(delta, self._reasoning_key, None)):
                yield ThinkPart(think=reasoning_content)

            # 转换文本内容
            if delta.content:
                yield TextPart(text=delta.content)

            # 转换工具调用
            for tool_call in delta.tool_calls or []:
                if tool_call.function.name:
                    yield ToolCall(
                        id=tool_call.id or str(uuid.uuid4()),
                        function=ToolCall.FunctionBody(
                            name=tool_call.function.name,
                            arguments=tool_call.function.arguments,
                        ),
                    )
                elif tool_call.function.arguments:
                    yield ToolCallPart(arguments_part=tool_call.function.arguments)
```

### 通信流程

```
LLM.chat_provider.generate()
  ↓
ChatProvider.generate()  [Protocol 方法]
  ↓
Kimi.generate()
  ↓
AsyncOpenAI.chat.completions.create()  [openai 官方 SDK]
  ↓
Kimi API (OpenAI 兼容)

# 或

Anthropic.generate()
  ↓
AsyncAnthropic.messages.create()  [anthropic 官方 SDK]
  ↓
Anthropic API
```

**核心特点**:
- Protocol 定义接口，运行时检查
- 每个 Provider 独立实现
- 直接使用官方 SDK
- 流式优先设计

---

## 6. 消息格式转换对比

### 输入消息转换

| 框架 | 内部消息类型 | 转换到 Provider 格式 |
|------|-------------|---------------------|
| **LitAI** | 无 (直接传参) | SDKLLM 内部处理 |
| **Republic** | `dict[str, Any]` | any-llm 内部处理 |
| **Pydantic AI** | `ModelMessage` | 每个 Model 子类实现 `_messages_to_xxx()` |
| **Kimi CLI** | `Message` | 每个 Provider 实现 `_convert_message()` |

### 输出消息转换

| 框架 | Provider 响应类型 | 内部响应类型 |
|------|------------------|-------------|
| **LitAI** | `V1ConversationResponseChunk` | `str` 或 `Iterator[str]` |
| **Republic** | `Any` (any-llm 统一) | `str` / `TextStream` / `StreamEvents` |
| **Pydantic AI** | SDK 原生类型 | `ModelResponse` / `StreamedResponse` |
| **Kimi CLI** | SDK 原生类型 | `StreamedMessage` (Protocol) |

---

## 7. 流式响应处理对比

### LitAI

```python
# 简单的 Iterator[str]
for chunk in llm.chat("hello", stream=True):
    print(chunk, end="", flush=True)
```

**特点**: 无事件系统，纯文本流。

### Republic

```python
# 结构化事件流
for event in llm.stream_events("Hello", tools=[...]):
    match event.kind:
        case "text":
            print(event.data["delta"])
        case "tool_call":
            handle_tool_call(event.data["call"])
        case "tool_result":
            handle_result(event.data["result"])
        case "usage":
            print(f"Tokens: {event.data}")
        case "final":
            print("Done!")
```

**特点**: `StreamEvent` 包含 kind + data，`StreamState` 携带 error 和 usage。

### Pydantic AI

```python
# 类型化事件流
async for event in agent.run_stream_events('Hello'):
    match event:
        case PartStartEvent(index, part):
            print(f"Part {index} started: {part}")
        case PartDeltaEvent(index, delta):
            if isinstance(delta, TextPartDelta):
                print(delta.content_delta)
        case PartEndEvent(index, part):
            print(f"Part {index} ended")
        case FinalResultEvent(tool_name, tool_call_id):
            print("Final result!")
```

**特点**: 类型化事件系统，每个事件都是具体类型。

### Kimi CLI

```python
# Protocol 定义的流式消息
async for part in await chat_provider.generate(system_prompt, tools, history):
    match part:
        case TextPart(text):
            print(text)
        case ThinkPart(think):
            print(f"[Thinking: {think}]")
        case ToolCall(id, function):
            handle_tool_call(part)
        case ToolCallPart(arguments_part):
            # 工具调用增量
            pass
```

**特点**: Protocol 定义，流式优先，支持增量合并。

---

## 8. 错误处理对比

### LitAI

```python
# 简单异常，无分类
try:
    response = llm.chat("Hello")
except Exception as e:
    print(f"Error: {e}")
```

### Republic

```python
# 结构化错误分类
from republic.core.errors import ErrorKind, RepublicError

try:
    response = llm.chat("Hello")
except RepublicError as e:
    match e.kind:
        case ErrorKind.CONFIG:
            print("配置错误，请检查 API Key")
        case ErrorKind.TEMPORARY:
            print("临时错误，可以重试")
        case ErrorKind.PROVIDER:
            print("Provider 错误，切换模型")
        case ErrorKind.INVALID_INPUT:
            print("输入无效，检查参数")
```

### Pydantic AI

```python
# 标准 Exception 子类
from pydantic_ai import ModelHTTPError, UnexpectedModelBehavior

try:
    response = await agent.run("Hello")
except ModelHTTPError as e:
    print(f"HTTP 错误: {e.status_code}")
except UnexpectedModelBehavior as e:
    print(f"模型行为异常: {e}")
```

### Kimi CLI

```python
# Provider 层级错误
from kosong.chat_provider import (
    ChatProviderError,
    APIConnectionError,
    APITimeoutError,
    APIStatusError,
)

try:
    async for part in await chat_provider.generate(...):
        pass
except APIConnectionError:
    print("连接失败")
except APITimeoutError:
    print("请求超时")
except APIStatusError as e:
    print(f"HTTP {e.status_code}: {e}")
```

---

## 9. 总结对比表

| 特性 | LitAI | Republic | Pydantic AI | Kimi CLI (kosong) |
|------|-------|----------|-------------|-------------------|
| **SDK 来源** | 私有 SDK | 第三方统一库 | 各 Provider 官方 SDK | 各 Provider 官方 SDK |
| **统一接口** | SDKLLM | AnyLLM | Model (ABC) | ChatProvider (Protocol) |
| **客户端管理** | 类级别缓存 | 实例级别缓存 | Provider 抽象 | 无缓存 |
| **消息转换** | SDK 内部 | any-llm 内部 | 每个 Model 实现 | 每个 Provider 实现 |
| **流式事件** | 无 | StreamEvent | ModelResponseStreamEvent | StreamedMessagePart |
| **错误分类** | 无 | ErrorKind 枚举 | Exception 子类 | ChatProviderError 层级 |
| **Provider 数量** | 统一网关 | 20+ | 20+ | 5 |

---

## 10. 设计决策总结

### 为什么选择不同的 SDK 策略？

| 策略 | 适用场景 | 优点 | 缺点 |
|------|----------|------|------|
| **私有统一 SDK** | 商业产品 | 统一计费、管理、监控 | 依赖单一供应商 |
| **第三方统一库** | 开源项目 | 最大化兼容性、快速开发 | 依赖中间层 |
| **各 Provider SDK** | 企业级应用 | 完全控制、支持特性差异化 | 维护成本高 |
| **Protocol + SDK** | 灵活扩展 | 解耦、易于扩展 | 需要实现转换 |

### 建议

1. **商业产品** → LitAI 模式 (统一网关)
2. **快速原型** → Republic 模式 (any-llm)
3. **企业级应用** → Pydantic AI 模式 (直接 SDK)
4. **终端应用** → Kimi CLI 模式 (Protocol)

---

*Last updated: 2026-02-25*
