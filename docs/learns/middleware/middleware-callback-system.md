# LLM 抽象层中的 Middleware/Callback 系统设计

> **相关主题**: [[error-handling-retries]], [[streaming-patterns]], [[observability-telemetry]]

## 概述

本文分析两个主流 LLM 抽象框架中的中间件和回调系统设计：**LangChain** 和 **Pydantic-AI**。这些模式对于构建可观测、可扩展和可调试的 LLM 应用程序至关重要。

## 核心概念

### 1. 回调系统架构

#### LangChain: 分层 Mixin-Based 设计

LangChain 采用精密的 Mixin 架构实现回调：

```
BaseCallbackHandler
├── LLMManagerMixin          (on_llm_start, on_llm_new_token, on_llm_end, on_llm_error)
├── ChainManagerMixin        (on_chain_start, on_chain_end, on_chain_error)
├── ToolManagerMixin         (on_tool_start, on_tool_end, on_tool_error)
├── RetrieverManagerMixin    (on_retriever_start, on_retriever_end, on_retriever_error)
├── CallbackManagerMixin     (on_llm_start, on_chat_model_start, on_chain_start, on_tool_start, on_retriever_start)
└── RunManagerMixin          (on_text, on_retry, on_custom_event)
```

**关键设计原则：**
- **关注点分离**: 每个 Mixin 处理特定组件类型（LLM、Chain、Tool、Retriever）
- **生命周期钩子**: 每个组件都有 `start`、`end` 和 `error` 回调
- **继承链**: Handler 可以继承多个 Mixin 来组合行为
- **异步支持**: 通过单独的 `AsyncCallbackHandler` 类支持异步操作

**位置**: `langchain/libs/core/langchain_core/callbacks/base.py:455-505`

```python
class BaseCallbackHandler(
    LLMManagerMixin,
    ChainManagerMixin,
    ToolManagerMixin,
    RetrieverManagerMixin,
    CallbackManagerMixin,
    RunManagerMixin,
):
    """基础回调处理器。"""
    raise_error: bool = False
    run_inline: bool = False
```

#### Pydantic-AI: 事件流 + 可观测性

Pydantic-AI 采用不同的方法：
1. **事件流处理器**: `EventStreamHandler` 用于流式事件处理
2. **OpenTelemetry 可观测性**: 通过 `InstrumentationSettings` 内置可观测性支持
3. **基于图的执行**: Agent 作为图节点运行

**位置**: `pydantic-ai/pydantic_ai_slim/pydantic_ai/agent/abstract.py:47-52`

```python
EventStreamHandler: TypeAlias = Callable[
    [RunContext[AgentDepsT], AsyncIterable[_messages.AgentStreamEvent]], Awaitable[None]
]
"""接收 Agent RunContext 和事件异步可迭代对象的函数。"""
```

### 2. 回调管理器模式

#### LangChain: 集中式管理器与运行上下文

`CallbackManager` 作为中央分发器：

```python
class CallbackManager(BaseCallbackManager):
    """LangChain 的回调管理器。"""

    def on_llm_start(
        self,
        serialized: dict[str, Any],
        prompts: list[str],
        run_id: UUID | None = None,
        **kwargs: Any,
    ) -> list[CallbackManagerForLLMRun]:
        # 分发到所有处理器
        handle_event(self.handlers, "on_llm_start", "ignore_llm", ...)
        # 返回运行管理器用于追踪
        return [CallbackManagerForLLMRun(...)]
```

**关键特性：**
- **Handler 注册**: 动态添加/移除处理器
- **继承性**: Handler 可以是可继承的（传播到子级）或本地的
- **标签与元数据**: 附加上下文信息到运行
- **父子关系**: 通过 `parent_run_id` 实现层级运行追踪

**位置**: `langchain/libs/core/langchain_core/callbacks/manager.py:1302-1408`

#### Pydantic-AI: 基于图节点的执行

Pydantic-AI 在节点级别集成回调：

```python
class UserPromptNode(AgentNode[DepsT, NodeRunEndT]):
    """处理用户提示和指令的节点。"""

    async def run(self, ctx: GraphRunContext[...]) -> ModelRequestNode | CallToolsNode:
        # 执行流经节点，每个节点可以发出事件
        return ModelRequestNode(...)
```

**位置**: `pydantic-ai/pydantic_ai_slim/pydantic_ai/_agent_graph.py:140-180`

### 3. 中间件链机制

#### LangChain: 带事件分发的 Handler 链

LangChain 使用函数式事件分发模式：

```python
def handle_event(
    handlers: list[BaseCallbackHandler],
    event_name: str,
    ignore_condition_name: str | None,
    *args: Any,
    **kwargs: Any,
) -> None:
    """CallbackManager 的通用事件处理器。"""
    coros: list[Coroutine] = []

    for handler in handlers:
        try:
            if ignore_condition_name is None or not getattr(handler, ignore_condition_name):
                event = getattr(handler, event_name)(*args, **kwargs)
                if asyncio.iscoroutine(event):
                    coros.append(event)
        except NotImplementedError:
            # chat_model_start -> llm_start 的回退处理
            if event_name == "on_chat_model_start":
                handle_event([handler], "on_llm_start", ...)
        except Exception as e:
            logger.warning("回调错误: %s", e)
            if handler.raise_error:
                raise
```

**位置**: `langchain/libs/core/langchain_core/callbacks/manager.py:254-335`

**关键设计模式：**
1. **忽略条件**: Handler 可以声明 `ignore_*` 属性来跳过事件
2. **回退链**: `on_chat_model_start` 回退到 `on_llm_start`
3. **异步聚合**: 收集协程并适当执行
4. **错误隔离**: 一个 handler 的错误不会破坏其他 handler

#### Pydantic-AI: 包装器模型模式

Pydantic-AI 使用装饰器/包装器模式实现中间件：

```python
@dataclass(init=False)
class WrapperModel(Model):
    """包装另一个模型的模型。用作基类。"""

    wrapped: Model

    async def request(self, messages, model_settings, model_request_parameters):
        # 预处理
        result = await self.wrapped.request(messages, model_settings, model_request_parameters)
        # 后处理
        return result

    @asynccontextmanager
    async def request_stream(self, messages, model_settings, model_request_parameters, run_context):
        async with self.wrapped.request_stream(...) as response_stream:
            # 可以拦截/修改流
            yield response_stream
```

**位置**: `pydantic-ai/pydantic_ai_slim/pydantic_ai/models/wrapper.py`

### 4. 关键回调点

#### LangChain 回调生命周期

| 组件 | 开始 | 新 Token | 结束 | 错误 |
|------|------|----------|------|------|
| LLM | `on_llm_start` | `on_llm_new_token` | `on_llm_end` | `on_llm_error` |
| Chat Model | `on_chat_model_start` | `on_llm_new_token` | `on_llm_end` | `on_llm_error` |
| Chain | `on_chain_start` | - | `on_chain_end` | `on_chain_error` |
| Tool | `on_tool_start` | - | `on_tool_end` | `on_tool_error` |
| Retriever | `on_retriever_start` | - | `on_retriever_end` | `on_retriever_error` |
| Agent | `on_agent_action` | - | `on_agent_finish` | (通过 chain/tool) |
| Retry | `on_retry` | - | - | - |
| Custom | `on_custom_event` | - | - | - |

#### Pydantic-AI 事件类型

```python
# Agent 流事件 (来自 messages.py)
AgentStreamEvent = (
    PartStartEvent
    | PartDeltaEvent
    | PartEndEvent
    | FunctionToolCallEvent
    | FunctionToolResultEvent
    | FinalResultEvent
)

# 在事件流处理器中的使用
async for event in agent_run:
    if isinstance(event, PartStartEvent):
        # 处理新部分（文本、工具调用等）
    elif isinstance(event, FunctionToolCallEvent):
        # 处理工具调用
    elif isinstance(event, FinalResultEvent):
        # 处理最终结果
```

### 5. 可观测性集成

#### LangChain: 可插拔追踪

LangChain 通过回调支持多种追踪后端：

```python
# 通过环境变量配置 LangSmith 追踪
# LANGCHAIN_TRACING_V2=true
# LANGCHAIN_API_KEY=...

# 自定义追踪器实现
class LangChainTracer(BaseCallbackHandler):
    def on_llm_start(self, serialized, prompts, **kwargs):
        # 发送到 LangSmith

    def on_llm_end(self, response, **kwargs):
        # 记录完成
```

**位置**: `langchain/libs/langchain/langchain_classic/callbacks/tracers/langchain.py`

#### Pydantic-AI: 原生 OpenTelemetry

Pydantic-AI 内置 OpenTelemetry 集成：

```python
@dataclass(init=False)
class InstrumentationSettings:
    """用于通过 OpenTelemetry 对模型和 Agent 进行可观测性配置的选项。"""

    tracer: Tracer
    logger: Logger
    event_mode: Literal['attributes', 'logs'] = 'attributes'
    include_binary_content: bool = True
    include_content: bool = True
    version: Literal[1, 2, 3, 4] = DEFAULT_INSTRUMENTATION_VERSION

    # 指标
    tokens_histogram: Histogram
    cost_histogram: Histogram
```

**位置**: `pydantic-ai/pydantic_ai_slim/pydantic_ai/models/instrumented.py:50-150`

## 代码示例

### LangChain: 自定义回调处理器

```python
from langchain_core.callbacks.base import BaseCallbackHandler
from langchain_core.outputs import LLMResult

class TokenCountingHandler(BaseCallbackHandler):
    """统计所有 LLM 调用的 Token 数量的自定义处理器。"""

    def __init__(self):
        self.total_tokens = 0
        self.prompt_tokens = 0
        self.completion_tokens = 0

    def on_llm_end(self, response: LLMResult, **kwargs) -> None:
        """LLM 完成时调用。"""
        for generation in response.generations:
            for gen in generation:
                if gen.generation_info:
                    usage = gen.generation_info.get('token_usage', {})
                    self.prompt_tokens += usage.get('prompt_tokens', 0)
                    self.completion_tokens += usage.get('completion_tokens', 0)
                    self.total_tokens += usage.get('total_tokens', 0)

    def on_llm_error(self, error: BaseException, **kwargs) -> None:
        """LLM 错误时调用。"""
        print(f"LLM 错误: {error}")

# 使用
handler = TokenCountingHandler()
llm = ChatOpenAI(callbacks=[handler])
result = llm.invoke("Hello!")
print(f"总 Token 使用量: {handler.total_tokens}")
```

**位置**: 模式基于 `langchain/libs/core/langchain_core/callbacks/usage.py`

### LangChain: 流式回调

```python
from langchain_core.callbacks.base import BaseCallbackHandler
import sys

class StreamingHandler(BaseCallbackHandler):
    """用于流式 LLM Token 的处理器。"""

    def on_llm_new_token(self, token: str, **kwargs) -> None:
        """每个 Token 生成时流式输出。"""
        sys.stdout.write(token)
        sys.stdout.flush()

    def on_llm_start(self, serialized, prompts, **kwargs) -> None:
        print("\n[LLM 开始]")

    def on_llm_end(self, response, **kwargs) -> None:
        print("\n[LLM 结束]")

# 流式使用
llm = ChatOpenAI(streaming=True, callbacks=[StreamingHandler()])
```

**位置**: `langchain/libs/core/langchain_core/callbacks/streaming_stdout.py`

### Pydantic-AI: 事件流处理器

```python
from pydantic_ai import Agent
from pydantic_ai.messages import AgentStreamEvent

async def custom_event_handler(ctx, event_stream):
    """Agent 事件的自定义处理器。"""
    async for event in event_stream:
        match event:
            case PartStartEvent(part=TextPart()):
                print(f"[文本开始]")
            case PartDeltaEvent(delta=TextPartDelta(content=text)):
                print(text, end="", flush=True)
            case FunctionToolCallEvent():
                print(f"[工具调用: {event.part.tool_name}]")
            case FunctionToolResultEvent():
                print(f"[工具结果]")

agent = Agent('openai:gpt-4o', event_stream_handler=custom_event_handler)
result = await agent.run("What is 2+2?")
```

**位置**: `pydantic-ai/pydantic_ai_slim/pydantic_ai/agent/abstract.py:300-350`

### Pydantic-AI: 自定义可观测性

```python
from pydantic_ai import Agent
from pydantic_ai.models.instrumented import InstrumentationSettings

# 配置可观测性
instrument = InstrumentationSettings(
    include_content=True,
    version=4,  # 最新的 OTel 规范
)

agent = Agent('openai:gpt-4o', instrument=instrument)

# 或为所有 Agent 配置可观测性
Agent.instrument_all(instrument)
```

**位置**: `pydantic-ai/pydantic_ai_slim/pydantic_ai/models/instrumented.py:60-120`

## 设计决策

### LangChain 设计理念

1. **显式回调注册**: 处理器必须显式传递给组件
2. **层级上下文**: 父子关系支持嵌套运行追踪
3. **同步/异步双重性**: 同步和异步操作有独立的代码路径
4. **错误恢复能力**: 回调错误不会破坏主执行
5. **Mixin 组合**: 通过多重继承灵活组合处理器

**权衡：**
- **优点**: 非常灵活，适用于任何 Python 代码
- **优点**: 丰富的预构建处理器生态
- **缺点**: 冗长的 API - 需要手动管理处理器
- **缺点**: 回调分发开销

### Pydantic-AI 设计理念

1. **基于图的执行**: Agent 作为状态机/图运行
2. **事件流**: 原生异步事件流支持实时更新
3. **OTel 优先**: 内置可观测性，非后期附加
4. **类型安全**: 大量使用泛型和类型别名
5. **包装器模式**: 通过模型包装实现中间件

**权衡：**
- **优点**: 现代、类型安全的 API
- **优点**: 原生流式和可观测性
- **优点**: 图模型支持复杂工作流
- **缺点**: 学习曲线更陡峭
- **缺点**: 生态系统不够成熟

## 相关文件

### LangChain
- `langchain/libs/core/langchain_core/callbacks/base.py` - 基础处理器和 Mixin 定义
- `langchain/libs/core/langchain_core/callbacks/manager.py` - CallbackManager 和运行管理器
- `langchain/libs/core/langchain_core/callbacks/stdout.py` - StdOutCallbackHandler 示例
- `langchain/libs/core/langchain_core/callbacks/streaming_stdout.py` - 流式处理器
- `langchain/libs/core/langchain_core/callbacks/file.py` - 文件输出处理器
- `langchain/libs/langchain/langchain_classic/callbacks/tracers/` - 追踪实现

### Pydantic-AI
- `pydantic-ai/pydantic_ai_slim/pydantic_ai/agent/abstract.py` - 带 event_stream_handler 的 AbstractAgent
- `pydantic-ai/pydantic_ai_slim/pydantic_ai/_agent_graph.py` - 基于图的 Agent 执行
- `pydantic-ai/pydantic_ai_slim/pydantic_ai/models/instrumented.py` - OTel 可观测性
- `pydantic-ai/pydantic_ai_slim/pydantic_ai/models/wrapper.py` - WrapperModel 中间件模式
- `pydantic-ai/pydantic_ai_slim/pydantic_ai/ui/_event_stream.py` - UI 事件流处理
- `pydantic-ai/pydantic_ai_slim/pydantic_ai/_instrumentation.py` - 可观测性命名

---

## 对 Rust LLM 抽象层设计的启示

基于以上分析，以下是 Rust LLM 抽象层的关键考虑因素：

### 1. 基于 Trait 的回调系统

Rust 的 Trait 系统非常适合实现类型安全的回调机制：

```rust
// 假设的 Rust 设计
trait CallbackHandler {
    fn on_llm_start(&mut self, ctx: &RunContext, prompts: &[String]);
    fn on_llm_new_token(&mut self, ctx: &RunContext, token: &str);
    fn on_llm_end(&mut self, ctx: &RunContext, result: &LLMResult);
    fn on_llm_error(&mut self, ctx: &RunContext, error: &Error);
    // ... 其他回调
}

// 可选回调的 Blanket 实现
trait CallbackHandlerExt: CallbackHandler {
    fn ignore_llm(&self) -> bool { false }
}
```

### 2. 通过 Tower 实现中间件链

`tower` crate 的 Service trait 非常适合中间件：

```rust
// 使用 tower::Service 实现中间件
pub struct LoggingMiddleware<S> {
    inner: S,
}

impl<S> Service<LLMRequest> for LoggingMiddleware<S> {
    type Response = S::Response;
    type Error = S::Error;
    type Future = S::Future;

    fn call(&mut self, req: LLMRequest) -> Self::Future {
        log::info!("LLM 请求: {:?}", req);
        self.inner.call(req)
    }
}
```

### 3. 使用 Tokio 进行事件流处理

利用 Tokio 的流处理能力：

```rust
use tokio_stream::Stream;

pub trait StreamingLLM {
    type TokenStream: Stream<Item = Token>;

    async fn stream(&self, prompt: &str) -> Self::TokenStream;
}

// 作为流转换器的回调
pub fn with_callbacks<S>(stream: S, handler: impl CallbackHandler) -> impl Stream<Item = Token> {
    stream.inspect(move |token| {
        handler.on_llm_new_token(token);
    })
}
```

### 4. OpenTelemetry 集成

使用 `opentelemetry` crate 实现原生可观测性：

```rust
use opentelemetry::trace::{Tracer, Span};

pub struct InstrumentedLLM<L> {
    inner: L,
    tracer: Tracer,
}

impl<L: LLM> LLM for InstrumentedLLM<L> {
    async fn complete(&self, prompt: &str) -> Result<String> {
        let mut span = self.tracer.start("llm.complete");
        span.set_attribute("prompt".into(), prompt.to_string().into());

        let result = self.inner.complete(prompt).await;

        match &result {
            Ok(response) => span.set_attribute("response".into(), response.clone().into()),
            Err(e) => span.set_status(opentelemetry::trace::Status::error(e.to_string())),
        }

        result
    }
}
```

### 5. 关键设计建议

1. **使用 Trait 实现回调**: Rust trait 为回调处理器提供零成本抽象
2. **利用 Tower**: Service trait 模式是中间件的成熟方案
3. **流式优先设计**: 使用 `impl Stream` 将流式作为一等概念构建
4. **OTel 原生**: 在核心集成 OpenTelemetry，而非事后附加
5. **类型安全**: 使用类型系统防止常见错误（如混合同步/异步）
6. **可组合性**: 通过 `ServiceBuilder` 模式允许中间件组合
7. **零成本**: 确保在未使用时回调开销被优化掉

---

*最后更新: 2026-02-26*
