# 五大 LLM 抽象层框架设计理念对比

> **Related topics**: [[kosong]], [[republic]], [[litai]], [[pydantic-ai]], [[langchain]]

## 概述

本文对比分析五个 LLM 抽象层框架的底层设计理念和架构模式：

| 框架 | 定位 | 核心哲学 |
|------|------|----------|
| **kosong** | LLM 抽象层 | Protocol-based，流式消息合并，为 Agent 设计 |
| **Pi AI** | 实时交互抽象层 | 事件驱动快照，双模接口 (Stream/Promise)，详尽的兼容性契约 |
| **republic** | Tape-first LLM 客户端 | 审计优先，any-llm 基础，结构化结果 |
| **litai** | LLM Router | 最小化框架，背景加载，统一计费 |
| **pydantic-ai** | Agent Framework | FastAPI 风格，类型安全，模型能力配置 |
| **LangChain** | 全能 LLM 框架 | Runnable 统一接口，LCEL 链式编排，回调驱动 |

---

## 1. kosong - Protocol-based 流式抽象

### 核心设计理念

**为现代 AI Agent 应用设计的轻量级抽象层**，强调：
- **Vendor Lock-in 免疫**：通过 Protocol 定义接口，而非继承
- **流式优先**：所有消息都以流式方式处理，自动合并片段
- **异步原生**：从底层支持异步工具编排

### 架构亮点

#### 1.1 Protocol-based Provider 接口

```python
@runtime_checkable
class ChatProvider(Protocol):
    """The interface of chat providers."""
    name: str
    
    @property
    def model_name(self) -> str: ...
    
    async def generate(
        self,
        system_prompt: str,
        tools: Sequence[Tool],
        history: Sequence[Message],
    ) -> "StreamedMessage": ...
```

**设计意图**：
- 不强制继承，任何实现 Protocol 的类都是合法 Provider
- `runtime_checkable` 支持运行时类型检查
- 接口简洁，只有核心方法

#### 1.2 流式消息片段合并机制

```python
class MergeableMixin:
    def merge_in_place(self, other: Any) -> bool:
        """Merge the other part into the current part."""
        return False

class TextPart(ContentPart):
    @override
    def merge_in_place(self, other: Any) -> bool:
        if not isinstance(other, TextPart):
            return False
        self.text += other.text  # 就地合并
        return True
```

**独特设计**：
- 流式响应的片段自动合并，上层无需处理片段分割
- `merge_in_place` 返回 bool 表示是否成功合并
- 支持 TextPart、ThinkPart、ToolCall 的合并

#### 1.3 统一的流式消息抽象

```python
type StreamedMessagePart = ContentPart | ToolCall | ToolCallPart

@runtime_checkable
class StreamedMessage(Protocol):
    def __aiter__(self) -> AsyncIterator[StreamedMessagePart]: ...
    
    @property
    def id(self) -> str | None: ...
    
    @property
    def usage(self) -> "TokenUsage | None": ...
```

**优势**：
- 统一处理文本、思考内容、工具调用
- TokenUsage 细分为 `input_other`, `input_cache_read`, `input_cache_creation`
- 支持延迟获取 usage 信息

#### 1.4 异步工具编排

```python
async def step(...) -> "StepResult":
    tool_result_futures: dict[str, ToolResultFuture] = {}
    
    async def on_tool_call(tool_call: ToolCall):
        result = toolset.handle(tool_call)
        if isinstance(result, ToolResult):
            future = ToolResultFuture()
            future.set_result(result)
            tool_result_futures[tool_call.id] = future
        else:
            result.add_done_callback(future_done_callback)
            tool_result_futures[tool_call.id] = result
```

**特点**：
- 工具调用立即返回 Future，不阻塞消息流
- 支持同步和异步工具的统一处理
- 取消时自动清理所有 pending futures

---

## 2. Pi AI (pi-mono) - 事件驱动与兼容性契约

### 核心设计理念
**为高性能实时交互设计的 LLM 抽象层**，强调：
- **UI/Agent 友好**：事件流原生携带最新快照，降低消费端复杂度。
- **双模消费**：同一个对象支持 AsyncIterator 流式处理和 Promise 最终结果获取。
- **极致兼容性**：通过详尽的兼容性标记 (Compat Flags) 抹平不同 Provider 的碎片化实现。

### 架构亮点

#### 2.1 携带快照的 AssistantMessageEvent
```typescript
export type AssistantMessageEvent =
    | { type: "text_delta"; delta: string; partial: AssistantMessage }
    | { type: "thinking_delta"; delta: string; partial: AssistantMessage }
    | { type: "toolcall_delta"; delta: string; partial: AssistantMessage }
    | { type: "done"; message: AssistantMessage };
```
**设计便利性**：
- 每个增量事件都包含 `partial` 字段，即当前已组装好的完整消息快照。
- Agent 或 UI 层无需自行维护 `fragments` 数组和字符串累加逻辑，极大地减少了状态同步错误。

#### 2.2 EventStream 的双模接口
```typescript
export class EventStream<T, R> implements AsyncIterable<T> {
    // 1. 支持异步迭代 (Streaming)
    async *[Symbol.asyncIterator](): AsyncIterator<T> { ... }
    
    // 2. 支持 Promise 获取最终结果 (Completing)
    result(): Promise<R> { return this.finalResultPromise; }
}
```
**设计便利性**：
- 允许 Agent 循环同时启动流式显示和后续逻辑等待：`const s = stream(); for await (const e of s) { render(e); } const final = await s.result();`。

#### 2.3 详尽的兼容性契约 (OpenAICompletionsCompat)
```typescript
export interface OpenAICompletionsCompat {
    supportsReasoningEffort?: boolean;
    requiresToolResultName?: boolean;
    requiresThinkingAsText?: boolean;
    requiresMistralToolIds?: boolean;
    thinkingFormat?: "openai" | "zai" | "qwen";
}
```
**设计便利性**：
- 将 Provider 的差异（如：Mistral 要求工具 ID 必须是 9 位字母数字）封装在底层。
- 上层 Agent 无需编写 `if (provider === 'mistral')` 这种带有“抽象泄漏”的代码。

#### 2.4 成本与缓存感知的 Usage
```typescript
export interface Usage {
    input: number;
    output: number;
    cacheRead: number;
    cacheWrite: number;
    cost: { total: number; ... };
}
```
**设计便利性**：
- 原生支持 Prompt 缓存层级的计费统计。
- Agent 可以根据 `cost` 反馈动态决定是否切换模型或执行上下文压缩。

---

## 3. republic - Tape-first 审计优先

### 核心设计理念

**Tape-first LLM 客户端**：所有交互都记录为结构化数据，支持完整的审计轨迹回放。

### 架构亮点

#### 2.1 基于 any-llm 的统一执行层

```python
class LLMCore:
    """Shared LLM execution utilities."""
    
    def get_client(self, provider: str) -> AnyLLM:
        """基于配置缓存客户端实例."""
        cache_key = self._freeze_cache_key(provider, api_key, api_base)
        if cache_key not in self._client_cache:
            self._client_cache[cache_key] = AnyLLM.create(...)
        return self._client_cache[cache_key]
```

**设计特点**：
- 依赖 any-llm 库处理多 provider 细节
- 客户端实例缓存（基于配置 fingerprint）
- 统一的错误分类体系（ErrorKind）

#### 2.2 多层错误分类与重试决策

```python
class AttemptDecision(Enum):
    RETRY_SAME_MODEL = auto()
    TRY_NEXT_MODEL = auto()

def _classify_anyllm_exception(self, exc: Exception) -> ErrorKind | None:
    error_map = [
        ((MissingApiKeyError, AuthenticationError), ErrorKind.CONFIG),
        ((RateLimitError, ContentFilterError), ErrorKind.TEMPORARY),
        ((ProviderError, AnyLLMError), ErrorKind.PROVIDER),
    ]

def _classify_by_http_status(self, exc: Exception) -> ErrorKind | None:
    if status in {401, 403}: return ErrorKind.CONFIG
    if status in {429}: return ErrorKind.TEMPORARY
```

**独特之处**：
- 三层分类策略：any-llm 异常 → HTTP 状态码 → 文本特征匹配
- 自动决策是重试当前模型还是切换到 fallback 模型
- 支持用户自定义 error_classifier

#### 2.3 ToolCallAssembler - 流式工具调用组装

```python
class ToolCallAssembler:
    """处理流式响应中 tool call 片段的组装."""
    
    def _resolve_key(self, tool_call: Any, position: int) -> object:
        """通过 id/index/position 三维定位 tool call."""
        call_id = getattr(tool_call, 'id', None)
        index = getattr(tool_call, 'index', None)
        
        if call_id is not None:
            return self._resolve_key_by_id(call_id, index, position)
        if index is not None:
            return self._resolve_key_by_index(tool_call, index, position)
        # 兜底：按位置定位
        return ("position", position)
```

**设计亮点**：
- 处理不同 provider 的 tool call 标识差异（有的用 id，有的用 index）
- 支持增量式参数组装（arguments 分多次返回）
- 保持 tool call 的原始顺序

#### 2.4 Tape - 不可变审计日志

```python
class TapeManager:
    """管理多 tape 的持久化和查询."""
    
    def record_chat(
        self,
        tape: str,
        run_id: str,
        system_prompt: str | None,
        new_messages: list[dict[str, Any]],
        response_text: str | None,
        tool_calls: list[dict[str, Any]] | None,
        tool_results: list[Any] | None,
        error: ErrorPayload | None,
        ...
    ) -> None:
        """记录完整的交互上下文."""
```

**特点**：
- 每个对话都有唯一的 tape name
- 记录完整的元数据（provider, model, usage, error）
- 支持 handoff（交接）机制，用于分割上下文窗口

---

## 3. litai - 最小化 Router 设计

### 核心设计理念

**零魔法、零学习成本的 LLM Router**，专注于：
- 模型路由和 fallback
- 统一计费（Lightning AI credits）
- 背景加载优化体验

### 架构亮点

#### 3.1 背景模型加载

```python
class LLM:
    _sdkllm_cache: Dict[str, SDKLLM] = {}
    
    def __init__(self, ...):
        # 后台线程加载模型
        threading.Thread(target=self._load_models, daemon=True).start()
    
    def _load_models(self) -> None:
        """Background loader for SDKLLM and fallback models."""
        key = f"{self._model}::{self._teamspace}::{self._enable_async}"
        if key not in self._sdkllm_cache:
            self._sdkllm_cache[key] = SDKLLM(...)
        # 预加载热门模型
        for cloudy_model in CLOUDY_MODELS:
            self._sdkllm_cache[preload_key] = SDKLLM(...)
```

**设计意图**：
- 构造函数立即返回，不阻塞用户
- 首次调用时等待加载完成（`_wait_for_model`）
- 全局缓存避免重复创建客户端

#### 3.2 简化的 Fallback 机制

```python
def chat(self, prompt: str, ...):
    models_to_try = []
    if model:  # 临时覆盖模型
        models_to_try.append(sdk_model)
    models_to_try.extend(self.models)  # 添加 fallback 链
    
    if self._enable_async:
        return loop.create_task(self.async_chat(models_to_try, ...))
    return self.sync_chat(models_to_try, ...)
```

**特点**：
- 简单的链式 fallback
- 同步/异步自动切换
- 支持运行时模型覆盖

#### 3.3 透传式响应处理

```python
def _model_call(self, model: SDKLLM, prompt: str, ...):
    """直接透传给底层 SDK."""
    response = model.chat(
        prompt=prompt,
        system_prompt=system_prompt,
        stream=stream,
        tools=tools,
        ...
    )
    if tools and isinstance(response, V1ConversationResponseChunk):
        return self._format_tool_response(response, auto_call_tools, lit_tools)
    return response
```

**设计哲学**：
- 最小封装，保留原始响应格式
- 工具调用可自动执行或返回原始调用
- 不过度抽象，保持与底层 API 的接近

---

## 4. pydantic-ai - FastAPI 风格的类型安全

### 核心设计理念

**将 FastAPI 的开发体验带到 GenAI 领域**，强调：
- 完全类型安全（"if it compiles, it works"）
- 强一致的抽象接口
- 模型能力配置（ModelProfile）

### 架构亮点

#### 4.1 强类型的 Model 抽象基类

```python
class Model(ABC):
    """Abstract class for a model."""
    
    @abstractmethod
    async def request(
        self,
        messages: list[ModelMessage],
        model_settings: ModelSettings | None,
        model_request_parameters: ModelRequestParameters,
    ) -> ModelResponse: ...

    @asynccontextmanager
    async def request_stream(
        self,
        messages: list[ModelMessage],
        model_settings: ModelSettings | None,
        model_request_parameters: ModelRequestParameters,
        run_context: RunContext[Any] | None = None,
    ) -> AsyncIterator[StreamedResponse]: ...
```

**设计特点**：
- 所有模型必须实现统一的 `request` 和 `request_stream`
- `ModelRequestParameters` 封装完整的请求配置（tools, output_mode, etc）
- `prepare_request` 钩子允许模型自定义请求准备流程

#### 4.2 ModelProfile - 声明式模型能力

```python
@dataclass
class ModelProfile:
    """声明模型支持的功能和能力."""
    
    supports_tools: bool = True
    supports_json_schema_output: bool = False
    supports_image_input: bool = False
    supports_image_output: bool = False
    supports_audio_input: bool = False
    supports_document_input: bool = False
    
    # 默认的结构化输出模式
    default_structured_output_mode: StructuredOutputMode = 'json-mode'
    
    # 支持的内置工具类型
    supported_builtin_tools: frozenset[type[AbstractBuiltinTool]] = frozenset()
```

**独特设计**：
- 每个模型实例都有 profile 描述其能力
- 运行时检查请求参数是否与模型能力匹配
- 支持通过 `customize_request_parameters` 调整工具 schema

#### 4.3 统一的 StreamedResponse 处理

```python
@dataclass
class StreamedResponse(ABC):
    """Streamed response from an LLM."""
    
    model_request_parameters: ModelRequestParameters
    _parts_manager: ModelResponsePartsManager = field(default_factory=ModelResponsePartsManager)
    
    def __aiter__(self) -> AsyncIterator[ModelResponseStreamEvent]:
        """Yield ModelResponseStreamEvent with final event detection."""
        
    @abstractmethod
    async def _get_event_iterator(self) -> AsyncIterator[ModelResponseStreamEvent]: ...
```

**特点**：
- `_parts_manager` 统一管理响应片段
- 自动检测并 emit `FinalResultEvent`
- 支持 PartStartEvent / PartEndEvent 的成对输出

#### 4.4 KnownModelName - 类型级别的模型发现

```python
KnownModelName = TypeAliasType(
    'KnownModelName',
    Literal[
        'anthropic:claude-3-5-haiku-20241022',
        'anthropic:claude-3-7-sonnet-20250219',
        'openai:gpt-5',
        ...  # 500+ 模型
    ],
)
```

**设计意图**：
- IDE 自动补全所有支持的模型
- 类型检查器可以在编译时发现无效模型名
- 同时保留 `str` 的灵活性用于新模型

---

## 5. LangChain - Runnable 统一接口与 LCEL 链式编排

### 核心设计理念

**最早的全功能 LLM 应用框架**，采用**回调驱动**架构，强调：
- **Runnable 统一接口**：所有组件（LLM、Chain、Agent、Tool）实现统一接口
- **LCEL 链式编排**：使用管道符 `|` 组合复杂工作流
- **回调系统**：丰富的回调钩子（on_llm_new_token, on_chain_end 等）
- **可组合性**：组件可任意组合，自动继承流式/异步能力

### 架构亮点

#### 5.1 Runnable 统一接口

```python
class Runnable(ABC, Generic[Input, Output]):
    """A unit of work that can be invoked, batched, streamed, transformed."""
    
    # 核心调用方法
    def invoke(self, input: Input, config: RunnableConfig | None = None) -> Output: ...
    async def ainvoke(self, input: Input, config: RunnableConfig | None = None) -> Output: ...
    
    # 批处理
    def batch(self, inputs: list[Input], config: RunnableConfig | None = None) -> list[Output]: ...
    async def abatch(self, inputs: list[Input], config: RunnableConfig | None = None) -> list[Output]: ...
    
    # 流式
    def stream(self, input: Input, config: RunnableConfig | None = None) -> Iterator[Output]: ...
    async def astream(self, input: Input, config: RunnableConfig | None = None) -> AsyncIterator[Output]: ...
    
    # 事件流（中间步骤可见）
    async def astream_events(self, input: Input, config: RunnableConfig | None = None, ...) -> AsyncIterator[StreamEvent]: ...
```

**独特设计**：
- 所有组件（LLM、Chain、Agent、Tool、Retriever）都实现 Runnable
- 使用 `|` 操作符组合链式调用（LCEL）
- 组合后的链自动继承 invoke/stream/batch/ainvoke/astream 能力

#### 5.2 LCEL (LangChain Expression Language)

```python
# 使用管道符声明式组合链
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import StrOutputParser
from langchain_openai import ChatOpenAI

prompt = ChatPromptTemplate.from_template("Tell me a joke about {topic}")
model = ChatOpenAI()
parser = StrOutputParser()

# LCEL 链式组合
chain = prompt | model | parser

# 自动支持所有 Runnable 方法
chain.invoke({"topic": "parrots"})           # 同步调用
await chain.ainvoke({"topic": "parrots"})    # 异步调用
for chunk in chain.stream({"topic": "parrots"}):  # 流式
    print(chunk, end="", flush=True)
```

**优势**：
- 声明式语法，代码即文档
- 组合后的链自动支持流式/异步/批处理
- 可通过 `config` 参数注入运行时配置（callbacks, metadata, tags）

#### 5.3 回调系统 (Callback System)

```python
from langchain_core.callbacks import BaseCallbackHandler

class WebSocketCallbackHandler(BaseCallbackHandler):
    """自定义回调处理器，用于 WebSocket 实时推送"""
    
    def on_llm_new_token(
        self,
        token: str,
        *,
        chunk: GenerationChunk | ChatGenerationChunk | None = None,
        run_id: UUID,
        parent_run_id: UUID | None = None,
        **kwargs: Any,
    ) -> Any:
        """每个新 token 产生时触发"""
        send_to_websocket({"type": "token", "content": token})
    
    def on_chain_end(
        self,
        outputs: dict[str, Any],
        *,
        run_id: UUID,
        **kwargs: Any,
    ) -> Any:
        """Chain 执行结束时触发"""
        send_to_websocket({"type": "done", "outputs": outputs})
    
    def on_tool_start(
        self,
        serialized: dict[str, Any],
        input_str: str,
        *,
        run_id: UUID,
        **kwargs: Any,
    ) -> Any:
        """工具开始执行时触发"""
        send_to_websocket({"type": "tool_start", "tool": serialized["name"]})

# 使用回调
chain.invoke(
    {"topic": "AI"},
    config={"callbacks": [WebSocketCallbackHandler()]}
)
```

**回调类型丰富**：
- `on_llm_start` / `on_llm_new_token` / `on_llm_end` / `on_llm_error`
- `on_chain_start` / `on_chain_end` / `on_chain_error`
- `on_tool_start` / `on_tool_end` / `on_tool_error`
- `on_agent_action` / `on_agent_finish`
- `on_retriever_start` / `on_retriever_end`

#### 5.4 消息块累加机制

```python
# LangChain 的消息块可以累加
chunks = []
async for chunk in model.astream("Hello, who are you?"):
    chunks.append(chunk)
    print(chunk.content, end="", flush=True)

# 累加所有块得到完整消息
full_message = chunks[0] + chunks[1] + chunks[2] + ...
# 或: full_message = sum(chunks[1:], chunks[0])
```

**特点**：
- `AIMessageChunk` / `ChatGenerationChunk` 支持 `+` 操作符
- 累加操作是幂等的，可随时获取当前完整状态
- 与 kosong 的 `merge_in_place` 类似，但更函数式

#### 5.5 astream_events - 中间步骤可见性

```python
# 流式事件提供中间步骤的完整可见性
async for event in chain.astream_events({"topic": "AI"}, version="v2"):
    match event["event"]:
        case "on_chain_start":
            print(f"Chain {event['name']} started")
        case "on_llm_stream":
            print(f"Token: {event['data']['chunk'].content}")
        case "on_tool_start":
            print(f"Tool {event['name']} called with {event['data']['input']}")
        case "on_chain_end":
            print(f"Chain finished with {event['data']['output']}")
```

**事件类型**：
- `on_*_start` / `on_*_end` - 组件生命周期
- `on_llm_stream` - LLM 流式输出
- `on_chain_stream` - Chain 中间结果流式
- `on_tool_start` / `on_tool_end` - 工具调用

### LangChain 的优缺点

**优点**：
- 生态系统最丰富（几百个集成）
- 回调系统强大，可观测性好
- LCEL 链式编排直观
- 向后兼容性好（发展了2年多）

**缺点**：
- 包体积大，依赖多（`langchain` + `langchain-core` + 各 provider 包）
- 学习曲线陡峭（概念多：Chain、Agent、Retriever、Memory、Callbacks）
- 某些设计显得过时（如早期的 Chain 基类 vs Runnable）
- 版本兼容性问题（0.1 → 0.2 → 0.3 多次重大重构）

---

## 对比总结

### 抽象层级对比

```
┌─────────────────────────────────────────────────────────────┐
│  litai          最薄封装，直接透传 SDK 响应                    │
│  ───────────────────────────────────────────────            │
│  Pi AI          事件流驱动，携带 partial 快照，双模接口         │
│  ───────────────────────────────────────────────            │
│  kosong         Protocol 抽象，流式片段自动合并                │
│  ───────────────────────────────────────────────            │
│  republic       审计优先，统一错误处理，any-llm 基础           │
│  ───────────────────────────────────────────────            │
│  pydantic-ai    强类型抽象，能力配置，类型安全                 │
│  ───────────────────────────────────────────────            │
│  LangChain      全能框架，Runnable 统一接口，LCEL 编排         │
└─────────────────────────────────────────────────────────────┘
```

### 流式处理对比

| 框架 | 流式抽象 | 片段合并 | 工具调用处理 |
|------|----------|----------|--------------|
| kosong | `StreamedMessage` Protocol | `merge_in_place` 就地合并 | 异步 Future 返回 |
| Pi AI | `AssistantMessageEventStream` | 事件中携带 `partial` 快照 | `toolcall_delta` 增量事件 |
| republic | `StreamEvents` / `TextStream` | `ToolCallAssembler` 组装 | 同步/异步执行器 |
| litai | 直接透传 SDK 流 | 无（原始流） | 可选自动执行 |
| pydantic-ai | `StreamedResponse` 基类 | `_parts_manager` 管理 | 通过 Agent 层处理 |
| LangChain | `Runnable.stream()` + Callback | `AIMessageChunk` + 累加 | Callback / 内置 Tool 执行 |

### 错误处理对比

| 框架 | 错误分类 | 重试机制 | Fallback |
|------|----------|----------|----------|
| kosong | 基础异常类型 | Provider 实现 | 无 |
| Pi AI | `StopReason` ("error" \| "aborted") | 外部 Agent 循环处理 | 无内置 |
| republic | `ErrorKind` 五类 | 自动决策重试/切换 | 链式 fallback |
| litai | 简单异常透传 | 固定次数重试 | 链式 fallback |
| pydantic-ai | `ModelHTTPError` | 通过 Agent/Graph 层 | 专用 FallbackModel |
| LangChain | 标准异常 + Callback `on_error` | tenacity 重试装饰器 | `with_fallbacks()` 包装 |

### 工具调用对比

| 框架 | 工具定义 | 执行模式 | Schema 生成 |
|------|----------|----------|-------------|
| kosong | `Tool` Protocol | 异步 Future | Pydantic 模型 |
| republic | `ToolSet` + `ToolExecutor` | 同步/异步 | 自动推断 |
| litai | `@tool` 装饰器 / `LitTool` | 自动/手动 | 函数签名 |
| pydantic-ai | `ToolDefinition` + `@tool` | Agent 编排 | Pydantic + Griffe |
| LangChain | `@tool` 装饰器 / `BaseTool` 子类 | Callback / Agent 执行 | 函数签名 + Pydantic |

---

## 适用场景建议

| 场景 | 推荐框架 | 理由 |
|------|----------|------|
| 快速原型/MVP | litai | 最简单，零学习成本 |
| **极致实时渲染 UI** | **Pi AI** | 事件流自带 partial 快照，UI 状态同步极简 |
| 生产级 Agent | kosong | 流式处理优雅，异步原生 |
| 审计合规需求 | republic | Tape-first，完整审计轨迹 |
| 大型复杂系统 | pydantic-ai | 类型安全，可维护性强 |
| 丰富生态集成 | LangChain | 几百个集成，最全的生态系统 |
| 复杂链式工作流 | LangChain | LCEL 编排，组件可任意组合 |
| 需要深度可观测性 | LangChain | 完善的回调系统，支持各种 tracer |

---

## 相关文件

- kosong: `kimi-cli/packages/kosong/src/kosong/`
  - `_generate.py` - 核心生成逻辑
  - `message.py` - 消息模型
  - `chat_provider/__init__.py` - Provider 协议
  
- republic: `republic/src/republic/`
  - `core/execution.py` - LLMCore 执行层
  - `clients/chat.py` - ChatClient 实现
  
- litai: `litai/src/litai/`
  - `llm.py` - 主 LLM 类
  
- pydantic-ai: `pydantic-ai/pydantic_ai_slim/pydantic_ai/`
  - `models/__init__.py` - Model 基类
  - `messages.py` - 消息类型

- LangChain: `langchain/libs/core/langchain_core/`
  - `runnables/base.py` - Runnable 基类
  - `language_models/llms.py` - LLM 抽象
  - `callbacks/base.py` - 回调基类
  - `tracers/event_stream.py` - 事件流实现

---

*Last updated: 2026-02-25*
