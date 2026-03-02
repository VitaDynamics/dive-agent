# Async Streaming 一等公民设计

> **Related topics**: [[streaming-comparison]]

## Overview

Async Streaming 作为一等公民的设计哲学强调：**流式不是响应的附加功能，而是交互的核心抽象**。这种设计模式下：

- 所有响应都通过流式接口提供，即使是一次性返回的完整内容
- 框架内部以流式为基础构建，非流式只是流式的聚合结果
- 支持细粒度的片段控制、背压和取消机制
- 统一的异步迭代器接口简化消费端代码

## Key Concepts

### 1. 框架对比分析

#### 1.1 kosong (kimi-cli)

**流式 API 设计**：⭐⭐⭐⭐⭐ 核心抽象

```python
# StreamedMessage 是核心 Protocol
@runtime_checkable
class StreamedMessage(Protocol):
    def __aiter__(self) -> AsyncIterator[StreamedMessagePart]:
        ...
    
    @property
    def id(self) -> str | None: ...
    
    @property
    def usage(self) -> "TokenUsage | None": ...
```

- **设计哲学**: `generate()` 始终返回 `StreamedMessage`，流式是唯一接口
- **数据流模式**: AsyncIterator (Pull模式) + Callback (Push模式) 混合
- **片段管理**: `merge_in_place()` 方法实现片段合并，支持 `ContentPart | ToolCall | ToolCallPart`
- **取消机制**: 完整的 `asyncio.CancelledError` 支持，自动清理未完成的 ToolResultFuture
- **错误处理**: 定义了清晰的错误层次结构 (`ChatProviderError` → `APIConnectionError`/`APITimeoutError`/`APIStatusError`)

**关键代码片段**:
```python
# packages/kosong/src/kosong/_generate.py
async for part in stream:
    if on_message_part:
        await callback(on_message_part, part.model_copy(deep=True))
    
    if pending_part is None:
        pending_part = part
    elif not pending_part.merge_in_place(part):
        _message_append(message, pending_part)
        if isinstance(pending_part, ToolCall) and on_tool_call:
            await callback(on_tool_call, pending_part)
        pending_part = part
```

#### 1.2 langchain

**流式 API 设计**：⭐⭐⭐ 附加功能（但基础架构支持良好）

- **设计哲学**: `BaseChatModel` 同时支持 `_generate` 和 `_stream`，流式是可选优化
- **数据流模式**: Callback-based (主要) + AsyncIterator (表层)
- **片段管理**: `ChatGenerationChunk` + `merge_chat_generation_chunks()` 合并
- **取消机制**: 通过 `disable_streaming` 标志控制，无原生取消支持
- **错误处理**: 错误通过回调传播，支持 `run_manager.on_llm_error()`

**关键代码片段**:
```python
# libs/core/langchain_core/language_models/chat_models.py
async for chunk in self._astream(input_messages, stop=stop, **kwargs):
    if chunk.message.id is None:
        chunk.message.id = run_id
    await run_manager.on_llm_new_token(
        cast("str", chunk.message.content), chunk=chunk
    )
    chunks.append(chunk)
    yield cast("AIMessageChunk", chunk.message)
```

**设计权衡**:
- ✅ 向后兼容性好，支持大量模型
- ✅ `disable_streaming` 提供灵活性
- ❌ 流式不是核心抽象，实现复杂度高
- ❌ Callback 模式增加了代码复杂度

#### 1.3 litai

**流式 API 设计**：⭐⭐⭐ 简单直接

- **设计哲学**: `chat()` 方法通过 `stream` 参数切换流式/非流式
- **数据流模式**: 迭代器模式 (`Iterator[str]` / `AsyncIterator[str]`)
- **片段管理**: 简单的字符串拼接，无复杂片段概念
- **取消机制**: 不支持显式取消
- **错误处理**: 重试机制内置于流式消费中

**关键代码片段**:
```python
# src/litai/llm.py
def chat(self, ..., stream: bool = False, ...) -> Union[str, Task[...], Iterator[str], None]:
    if stream:
        return self.sync_chat(..., stream=True)
    return self.sync_chat(..., stream=False)

async def _peek_and_rebuild_async(self, agen: AsyncIterator[str]) -> Optional[AsyncIterator[str]]:
    # Peek 检查非空内容后重建迭代器
    peeked_items: List[str] = []
    async for item in agen:
        peeked_items.append(item)
        if item != "":
            has_content_found = True
            break
    # ... 重建迭代器
```

**设计权衡**:
- ✅ API 简单，易于使用
- ✅ 支持模型回退 (fallback) 和重试
- ❌ 流式作为参数切换，不是一等公民
- ❌ 缺少细粒度的片段控制

#### 1.4 pydantic-ai

**流式 API 设计**：⭐⭐⭐⭐⭐ 一等公民，功能最完善

- **设计哲学**: `run_stream()` 返回 `StreamedRunResult`，流式是独立一等模式
- **数据流模式**: AsyncIterator + 结构化事件系统 (`ModelResponseStreamEvent`)
- **片段管理**: `ModelResponsePartsManager` 专业管理片段生命周期
- **取消机制**: Async context manager (`async with agent.run_stream()`) 支持自动清理
- **错误处理**: 内置验证错误处理，支持部分验证 (`allow_partial`)

**关键架构组件**:

1. **AgentStream**: 核心流式结果类
```python
# pydantic_ai_slim/pydantic_ai/result.py
@dataclass(kw_only=True)
class AgentStream(Generic[AgentDepsT, OutputDataT]):
    async def stream_text(self, *, delta: bool = False, debounce_by: float | None = 0.1) -> AsyncIterator[str]:
        ...
    
    async def stream_output(self, *, debounce_by: float | None = 0.1) -> AsyncIterator[OutputDataT]:
        ...
    
    async def stream_responses(self, *, debounce_by: float | None = 0.1) -> AsyncIterator[_messages.ModelResponse]:
        ...
```

2. **ModelResponsePartsManager**: 片段管理器
```python
# pydantic_ai_slim/pydantic_ai/_parts_manager.py
@dataclass
class ModelResponsePartsManager:
    _parts: list[ManagedPart] = field(default_factory=list[ManagedPart], init=False)
    _vendor_id_to_part_index: dict[VendorId, int] = field(default_factory=dict[VendorId, int], init=False)
    
    def handle_text_delta(self, *, vendor_part_id: VendorId | None, content: str, ...) -> Iterator[ModelResponseStreamEvent]:
        # 智能判断是新建 Part 还是更新现有 Part
        
    def handle_tool_call_delta(self, *, vendor_part_id: Hashable | None, tool_name: str | None, ...) -> ModelResponseStreamEvent | None:
        # 管理 ToolCallPartDelta → ToolCallPart 的升级
```

3. **结构化事件系统**:
```python
# pydantic_ai_slim/pydantic_ai/messages.py
ModelResponseStreamEvent = Annotated[
    Union[
        PartStartEvent,      # 新 Part 开始
        PartDeltaEvent,      # Part 更新
        PartEndEvent,        # Part 结束
        FinalResultEvent,    # 最终结果
    ],
    Field(discriminator='event_kind'),
]
```

**设计权衡**:
- ✅ 功能最完善，支持 debounce、delta 模式、部分验证
- ✅ 类型安全，泛型支持 `OutputDataT`
- ✅ 事件系统清晰，支持复杂场景
- ❌ 实现复杂度高，学习曲线陡峭

#### 1.5 republic

**流式 API 设计**：⭐⭐⭐⭐ 核心功能

- **设计哲学**: `stream()` 和 `stream_async()` 是独立方法，与 `chat()` 并列
- **数据流模式**: 迭代器模式 + 结构化事件流 (`StreamEvent`)
- **片段管理**: 简单的事件封装，无复杂片段合并
- **取消机制**: 通过迭代器协议支持
- **错误处理**: `StreamState` 统一承载错误和使用信息

**关键代码片段**:
```python
# src/republic/core/results.py
@dataclass(frozen=True)
class StreamEvent:
    kind: Literal["text", "tool_call", "tool_result", "usage", "error", "final"]
    data: dict[str, Any]

class AsyncTextStream:
    def __aiter__(self) -> AsyncIterator[str]:
        return self._iterator
    
    @property
    def error(self) -> ErrorPayload | None:
        return self._state.error
    
    @property
    def usage(self) -> dict[str, Any] | None:
        return self._state.usage
```

**设计权衡**:
- ✅ API 简洁，`stream` 和 `stream_events` 两种粒度
- ✅ `StreamState` 统一状态管理
- ❌ 事件类型固定为 `dict[str, Any]`，类型安全性较弱
- ❌ 片段管理功能较简单

### 2. 设计模式总结

#### 2.1 一等公民 Streaming 的共同特征

| 特征 | kosong | pydantic-ai | republic | litai | langchain |
|------|--------|-------------|----------|-------|-----------|
| 流式为核心抽象 | ✅ | ✅ | ⚠️ (独立方法) | ❌ | ❌ |
| AsyncIterator 原生支持 | ✅ | ✅ | ✅ | ✅ | ✅ |
| 回调机制 | ✅ | ✅ | ❌ | ❌ | ✅ |
| 片段合并/管理 | ✅ 手动 | ✅ 专业管理器 | ❌ | ❌ | ⚠️ Chunk合并 |
| 背压/防抖支持 | ❌ | ✅ `debounce_by` | ❌ | ❌ | ❌ |
| 取消机制 | ✅ | ✅ | ⚠️ | ❌ | ⚠️ |
| 类型安全 | ✅ | ✅⭐ (泛型) | ⚠️ | ✅ | ✅ |

#### 2.2 数据流模式对比

**Push 模式 (Callback)**:
```python
# kosong 示例
async def on_message_part(part: StreamedMessagePart):
    print(part)

await kosong.step(..., on_message_part=on_message_part)
```
- 优点: 实时响应，适合UI更新
- 缺点: 控制流分散，难以组合

**Pull 模式 (AsyncIterator)**:
```python
# pydantic-ai 示例
async with agent.run_stream('Hello') as result:
    async for text in result.stream_text():
        print(text)
```
- 优点: 控制流清晰，支持背压
- 缺点: 需要消费者主动拉取

**混合模式**:
```python
# kosong 支持两者
stream = await chat_provider.generate(...)
async for part in stream:  # Pull
    await callback(on_message_part, part)  # Push
```

#### 2.3 片段管理机制

| 框架 | 机制 | 特点 |
|------|------|------|
| kosong | `merge_in_place()` | 简单，支持 ContentPart/ToolCall 合并 |
| pydantic-ai | `ModelResponsePartsManager` | 专业，支持 Delta → Part 升级、多Part类型 |
| langchain | `merge_chat_generation_chunks()` | 外部合并，模型无关 |
| litai | 无 | 简单字符串流 |
| republic | 无 | 事件封装 |

## Code Examples

### 流式文本生成

```python
# kosong
stream = await kimi.generate(system_prompt, tools, history)
async for part in stream:
    if isinstance(part, TextPart):
        print(part.text, end="")

# pydantic-ai
async with agent.run_stream('Hello') as result:
    async for text in result.stream_text(delta=True):
        print(text, end="")

# republic
stream = llm.stream("Hello")
for chunk in stream:
    print(chunk, end="")

# litai
result = llm.chat("Hello", stream=True)
if isinstance(result, Iterator):
    for chunk in result:
        print(chunk, end="")
```

### 结构化事件流

```python
# pydantic-ai - 最完整的事件系统
async with agent.run_stream('Hello') as result:
    async for event in result._raw_stream_response:
        match event:
            case PartStartEvent(index=idx, part=part):
                print(f"New part at {idx}: {part}")
            case PartDeltaEvent(index=idx, delta=delta):
                print(f"Delta at {idx}: {delta}")
            case FinalResultEvent():
                print("Stream complete")

# republic - 简单的事件类型
for event in llm.stream_events("Hello", tools=[...]):
    match event.kind:
        case "text":
            print(event.data["delta"], end="")
        case "tool_call":
            print(f"Tool call: {event.data}")
        case "final":
            print("\nDone")
```

### 工具调用流式处理

```python
# kosong - 支持异步工具结果
async def on_tool_call(tool_call: ToolCall):
    result = toolset.handle(tool_call)
    if isinstance(result, ToolResultFuture):
        result.add_done_callback(lambda f: print(f.result()))

await kosong.step(..., on_tool_call=on_tool_call)

# pydantic-ai - 自动工具调用
async with agent.run_stream('Calculate 2+2') as result:
    async for output in result.stream_output():
        print(output)  # 自动处理工具调用并流式返回
```

## Design Decisions

### 为什么 pydantic-ai 做得最好？

1. **专业的事件系统**: `PartStartEvent`/`PartDeltaEvent`/`PartEndEvent` 清晰区分片段生命周期
2. **防抖支持**: `debounce_by` 参数对结构化输出验证至关重要
3. **增量模式**: `delta=True/False` 满足不同场景需求
4. **部分验证**: `allow_partial` 支持流式验证结构化输出
5. **统一的管理器**: `ModelResponsePartsManager` 将片段复杂度封装在单一组件

### kosong 的优势

1. **简洁的 Protocol 设计**: `StreamedMessage` 作为 Protocol 易于扩展
2. **优秀的取消支持**: 完整的 `asyncio.CancelledError` 处理，自动清理资源
3. **混合模式**: 同时支持 Pull 和 Push，适应不同场景

### langchain 的权衡

- **兼容性优先**: 需要支持大量遗留模型，无法将流式作为唯一抽象
- **Callback 复杂性**: 历史包袱导致回调系统复杂，但提供了强大的追踪能力

### litai 的定位

- **简单至上**: 适合快速原型，但缺乏复杂场景支持
- **同步优先**: 异步支持通过 `nest_asyncio` 实现，不够原生

### 最佳实践建议

1. **新框架设计**: 参考 pydantic-ai 的事件系统 + kosong 的 Protocol 设计
2. **取消机制**: 必须支持，参考 kosong 的 `asyncio.CancelledError` 处理
3. **类型安全**: 使用泛型 `OutputDataT` 如 pydantic-ai
4. **防抖**: 结构化输出场景必须支持
5. **API 设计**: 提供多层次的流式接口 (`stream_text` / `stream_output` / `stream_responses`)

## Related Files

### kosong
- `/infra-LLM /kimi-cli/packages/kosong/src/kosong/__init__.py` - 主入口，step() 实现
- `/infra-LLM /kimi-cli/packages/kosong/src/kosong/_generate.py` - generate() 核心实现
- `/infra-LLM /kimi-cli/packages/kosong/src/kosong/chat_provider/__init__.py` - StreamedMessage Protocol
- `/infra-LLM /kimi-cli/packages/kosong/src/kosong/chat_provider/kimi.py` - KimiStreamedMessage 实现

### langchain
- `/infra-LLM /langchain/libs/core/langchain_core/language_models/chat_models.py` - BaseChatModel
- `/infra-LLM /langchain/libs/core/langchain_core/runnables/base.py` - Runnable 接口
- `/infra-LLM /langchain/libs/core/langchain_core/tracers/_streaming.py` - StreamingCallbackHandler

### litai
- `/infra-LLM /litai/src/litai/llm.py` - LLM 类，stream 支持

### pydantic-ai
- `/infra-LLM /pydantic-ai/pydantic_ai_slim/pydantic_ai/result.py` - AgentStream, StreamedRunResult
- `/infra-LLM /pydantic-ai/pydantic_ai_slim/pydantic_ai/_parts_manager.py` - ModelResponsePartsManager
- `/infra-LLM /pydantic-ai/pydantic_ai_slim/pydantic_ai/messages.py` - ModelResponseStreamEvent
- `/infra-LLM /pydantic-ai/tests/test_streaming.py` - 流式测试

### republic
- `/infra-LLM /republic/src/republic/llm.py` - LLM 类，stream/stream_events 方法
- `/infra-LLM /republic/src/republic/core/results.py` - TextStream, AsyncTextStream, StreamEvent
- `/infra-LLM /republic/examples/04_stream_events.py` - 流式示例
