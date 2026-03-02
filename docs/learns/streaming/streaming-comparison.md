# 五大框架流式消息处理深度对比

> **Related topics**: [[llm-abstraction-comparison]], [[kosong]], [[republic]], [[litai]], [[pydantic-ai]], [[langchain]]

## 概述

本文深入对比五个框架对流式（Streaming）消息的处理机制，评估它们是否将流式支持作为**一等公民（First-class Citizen）**。

### 一等公民的评判标准

1. **API 设计**：流式是否是核心抽象，还是事后添加的
2. **数据流模式**：推模式（Push）vs 拉模式（Pull），是否支持背压
3. **片段管理**：如何处理流式片段的组装和合并
4. **工具调用**：流式响应中工具调用的处理能力
5. **错误处理**：流式过程中的错误传播和恢复
6. **取消机制**：是否支持优雅的流式取消

---

## 1. kosong - 流式原生设计

### 核心架构：Protocol-based 流式抽象

```python
@runtime_checkable
class StreamedMessage(Protocol):
    def __aiter__(self) -> AsyncIterator[StreamedMessagePart]: ...
    
    @property
    def id(self) -> str | None: ...
    
    @property
    def usage(self) -> "TokenUsage | None": ...
```

### 流式处理流水线

```
ChatProvider.generate() 
    ↓
StreamedMessage (Async Iterator)
    ↓
_generate() 合并片段
    ↓
GenerateResult (完整消息)
```

### 独特设计：merge_in_place 就地合并

```python
async def generate(...):
    message = Message(role="assistant", content=[])
    pending_part: StreamedMessagePart | None = None
    
    async for part in stream:
        if on_message_part:
            await callback(on_message_part, part.model_copy(deep=True))
        
        if pending_part is None:
            pending_part = part
        elif not pending_part.merge_in_place(part):  # 尝试合并
            # 无法合并，保存 pending，开始新 part
            _message_append(message, pending_part)
            pending_part = part
```

**优势**：
- **延迟极低**：片段到达立即通过 callback 通知上层
- **自动合并**：文本片段自动拼接，工具调用参数增量组装
- **内存友好**：不会缓存所有原始片段

### 工具调用的流式处理

```python
# ToolCall 和 ToolCallPart 的协作
class ToolCall(BaseModel, MergeableMixin):
    @override
    def merge_in_place(self, other: Any) -> bool:
        if not isinstance(other, ToolCallPart):
            return False
        if self.function.arguments is None:
            self.function.arguments = other.arguments_part
        else:
            self.function.arguments += other.arguments_part or ""
        return True
```

**关键洞察**：
- `ToolCallPart` 是流式片段（arguments_part）
- `ToolCall` 是完整工具调用
- 通过 `merge_in_place` 实现增量组装

### 流式一等公民指数：⭐⭐⭐⭐⭐ (5/5)

| 维度 | 评分 | 说明 |
|------|------|------|
| API 设计 | ⭐⭐⭐⭐⭐ | Protocol 原生支持流式 |
| 数据流模式 | ⭐⭐⭐⭐⭐ | 拉模式（AsyncIterator）+ Callback 推模式 |
| 片段管理 | ⭐⭐⭐⭐⭐ | 自动合并，上层无感知 |
| 工具调用 | ⭐⭐⭐⭐⭐ | 原生支持增量组装 |
| 错误处理 | ⭐⭐⭐⭐ | 异常直接抛出，需上层处理 |
| 取消机制 | ⭐⭐⭐⭐ | asyncio.CancelledError 支持 |

---

## 2. republic - 双轨流式系统

### 核心架构：TextStream vs StreamEvents

```python
# 纯文本流
class TextStream:
    def __iter__(self) -> Iterator[str]: ...
    @property
    def error(self) -> ErrorPayload | None: ...
    @property
    def usage(self) -> dict[str, Any] | None: ...

# 结构化事件流
@dataclass(frozen=True)
class StreamEvent:
    kind: Literal["text", "tool_call", "tool_result", "usage", "error", "final"]
    data: dict[str, Any]
```

### 流式处理流水线

```
LLMCore.run_chat_sync(stream=True)
    ↓
SDK 流式响应
    ↓
TextStream / StreamEvents (包装器)
    ↓
Iterator[StreamEvent] 或 Iterator[str]
```

### 独特设计：ToolCallAssembler

```python
def _build_text_stream(...):
    assembler = ToolCallAssembler()
    
    def _iterator() -> Iterator[str]:
        for chunk in response:
            deltas = self._extract_chunk_tool_call_deltas(chunk)
            if deltas:
                assembler.add_deltas(deltas)  # 增量组装
            text = self._extract_chunk_text(chunk)
            if text:
                yield text
```

**ToolCallAssembler 的复杂逻辑**：

```python
def _resolve_key(self, tool_call: Any, position: int) -> object:
    """三维定位：id → index → position"""
    call_id = getattr(tool_call, 'id', None)
    index = getattr(tool_call, 'index', None)
    
    if call_id is not None:
        return self._resolve_key_by_id(call_id, index, position)
    if index is not None:
        return self._resolve_key_by_index(tool_call, index, position)
    return ("position", position)  # 兜底
```

### 两种流式 API 对比

| API | 适用场景 | 特点 |
|-----|----------|------|
| `stream()` | 纯文本展示 | 简单，只 yield str |
| `stream_events()` | 复杂交互 | 结构化事件，包含 tool_call/tool_result |

### 错误处理：状态累积模式

```python
@dataclass
class StreamState:
    error: ErrorPayload | None = None
    usage: dict[str, Any] | None = None

class TextStream:
    def __init__(self, iterator: Iterator[str], *, state: StreamState):
        self._iterator = iterator
        self._state = state
```

**特点**：错误不会立即抛出，而是累积在 state 中

### 流式一等公民指数：⭐⭐⭐⭐ (4/5)

| 维度 | 评分 | 说明 |
|------|------|------|
| API 设计 | ⭐⭐⭐⭐ | 专门的 stream/stream_events 方法 |
| 数据流模式 | ⭐⭐⭐⭐ | 纯拉模式（Iterator） |
| 片段管理 | ⭐⭐⭐⭐ | ToolCallAssembler 处理复杂场景 |
| 工具调用 | ⭐⭐⭐⭐ | 支持，但只在 StreamEvents 中 |
| 错误处理 | ⭐⭐⭐⭐ | State 累积模式 |
| 取消机制 | ⭐⭐⭐ | 依赖 Python 迭代器协议 |

---

## 3. litai - 透传式流式

### 核心架构：直接透传 SDK 流

```python
def chat(self, ..., stream: bool = False):
    if self._enable_async:
        return loop.create_task(self.async_chat(models_to_try, ..., stream=stream))
    return self.sync_chat(models_to_try, ..., stream=stream)
```

### 流式处理流水线

```
LLM.chat(stream=True)
    ↓
sync_chat / async_chat
    ↓
SDKLLM.chat(stream=True)  [透传]
    ↓
原始 SDK 流式响应
```

### 独特设计：Peek and Rebuild

```python
async def _peek_and_rebuild_async(
    self, agen: AsyncIterator[str]
) -> Optional[AsyncIterator[str]]:
    """窥探迭代器，检查非空内容后重建"""
    peeked_items: List[str] = []
    has_content_found = False
    
    async for item in agen:
        peeked_items.append(item)
        if item != "":
            has_content_found = True
            break
    
    if has_content_found:
        async def rebuilt() -> AsyncIterator[str]:
            for peeked_item in peeked_items:
                yield peeked_item
            async for remaining_item in agen:
                yield remaining_item
        return rebuilt()
    return None
```

**同步版本使用 `itertools.tee`**：

```python
peek_iter, return_iter = itertools.tee(response)
has_content = False
for chunk in peek_iter:
    if chunk != "":
        has_content = True
        break
if has_content:
    return return_iter
```

### 极简流式哲学

```python
# 调用方式
for chunk in llm.chat("Hello", stream=True):
    print(chunk, end="")
```

**特点**：
- 无中间抽象层，直接返回 `Iterator[str]`
- 工具调用不支持流式（返回完整 tool_calls）
- 无片段管理，原始流透传

### 流式一等公民指数：⭐⭐⭐ (3/5)

| 维度 | 评分 | 说明 |
|------|------|------|
| API 设计 | ⭐⭐⭐ | stream 参数控制，返回类型不统一 |
| 数据流模式 | ⭐⭐⭐⭐ | 纯拉模式，简单直接 |
| 片段管理 | ⭐⭐ | 无，直接透传 SDK |
| 工具调用 | ⭐⭐ | 不支持流式工具调用 |
| 错误处理 | ⭐⭐⭐ | 常规异常抛出 |
| 取消机制 | ⭐⭐⭐ | 依赖 Python 迭代器 |

---

## 4. pydantic-ai - 结构化流式

### 核心架构：StreamedResponse + PartsManager

```python
@dataclass
class StreamedResponse(ABC):
    model_request_parameters: ModelRequestParameters
    _parts_manager: ModelResponsePartsManager
    _event_iterator: AsyncIterator[ModelResponseStreamEvent] | None = None
    
    def __aiter__(self) -> AsyncIterator[ModelResponseStreamEvent]: ...
    
    @abstractmethod
    async def _get_event_iterator(self) -> AsyncIterator[ModelResponseStreamEvent]: ...
```

### 流式处理流水线

```
Model.request_stream()
    ↓
StreamedResponse
    ↓
PartsManager 处理 deltas
    ↓
ModelResponseStreamEvent (PartStartEvent, PartDeltaEvent, PartEndEvent)
    ↓
FinalResultEvent (检测完成)
```

### 独特设计：ModelResponsePartsManager

```python
@dataclass
class ModelResponsePartsManager:
    _parts: list[ManagedPart] = field(default_factory=list)
    _vendor_id_to_part_index: dict[VendorId, int] = field(default_factory=dict)
    
    def handle_text_delta(
        self,
        *,
        vendor_part_id: VendorId | None,
        content: str,
        ...
    ) -> Iterator[ModelResponseStreamEvent]:
        # 查找或创建 TextPart
        # 应用 delta
        # yield PartStartEvent 或 PartDeltaEvent
```

**事件类型丰富**：

```python
ModelResponseStreamEvent = (
    PartStartEvent      # 新 part 开始
    | PartDeltaEvent    # part 更新
    | PartEndEvent      # part 结束
    | FinalResultEvent  # 最终结果匹配
)
```

### 流式装饰器链

```python
def __aiter__(self):
    if self._event_iterator is None:
        # 链式装饰器
        self._event_iterator = iterator_with_part_end(
            iterator_with_final_event(
                self._get_event_iterator()
            )
        )
    return self._event_iterator
```

**功能**：
- `iterator_with_final_event`：检测最终结果并插入事件
- `iterator_with_part_end`：为 TextPart/ThinkingPart/BaseToolCallPart 生成结束事件

### 工具调用流式处理

```python
def handle_tool_call_delta(
    self,
    *,
    vendor_part_id: Hashable | None,
    tool_name: str | None = None,
    args: str | dict[str, Any] | None = None,
    ...
) -> ModelResponseStreamEvent | None:
    # ToolCallPartDelta → ToolCallPart 的升级逻辑
    if isinstance(updated_part, ToolCallPart):
        if isinstance(existing_part, ToolCallPartDelta):
            # Delta 升级为完整 Part
            return PartStartEvent(index=part_index, part=updated_part)
```

### 流式一等公民指数：⭐⭐⭐⭐⭐ (5/5)

| 维度 | 评分 | 说明 |
|------|------|------|
| API 设计 | ⭐⭐⭐⭐⭐ | 专门的 request_stream 方法，类型完整 |
| 数据流模式 | ⭐⭐⭐⭐⭐ | 拉模式 + 丰富的事件类型 |
| 片段管理 | ⭐⭐⭐⭐⭐ | PartsManager 专业处理 |
| 工具调用 | ⭐⭐⭐⭐⭐ | 原生支持增量组装 |
| 错误处理 | ⭐⭐⭐⭐ | 通过事件传播 |
| 取消机制 | ⭐⭐⭐⭐ | async context manager 支持 |

---

## 5. LangChain - 回调驱动的流式架构

### 核心架构：Runnable + Callback 双模式

LangChain 提供**两种**流式机制：

```python
# 模式 1: 标准流式（拉模式）
async for chunk in model.astream("Hello"):
    print(chunk.content, end="")

# 模式 2: 事件流（中间步骤可见）
async for event in chain.astream_events({"topic": "AI"}, version="v2"):
    if event["event"] == "on_llm_stream":
        print(event["data"]["chunk"].content, end="")
```

### 流式处理流水线

```
Runnable.astream() / astream_events()
    ↓
CallbackManager (触发回调)
    ↓
BaseCallbackHandler.on_llm_new_token()  [推模式]
    ↓
Iterator/AsyncIterator yield chunk      [拉模式]
    ↓
AIMessageChunk (可累加)
```

### 独特设计：Callback 与 Iterator 双轨制

```python
# 拉模式：使用 astream
class MyWebSocketHandler:
    async def handle(self, message: str):
        async for chunk in self.chain.astream({"input": message}):
            await self.websocket.send(chunk.content)

# 推模式：使用 Callback
class WebSocketCallbackHandler(BaseCallbackHandler):
    def on_llm_new_token(self, token: str, *, chunk, run_id, **kwargs):
        # 每个 token 产生时立即推送
        asyncio.create_task(self.websocket.send(token))
    
    def on_tool_start(self, serialized, input_str, *, run_id, **kwargs):
        # 工具开始执行时通知
        asyncio.create_task(self.websocket.send({"type": "tool_start", "tool": serialized["name"]}))

# 组合使用：Callback 实现推模式，Iterator 实现拉模式
chain.invoke(
    {"input": "Hello"},
    config={"callbacks": [WebSocketCallbackHandler()]}  # 推
)
# 同时
async for chunk in chain.astream({"input": "Hello"}):   # 拉
    pass
```

**双模式优势**：
- **推模式（Callback）**：适合 WebSocket 实时推送，零延迟
- **拉模式（Iterator）**：适合消费者控制节奏，支持背压

### 消息块累加机制

```python
# LangChain 的消息块设计
class AIMessageChunk(BaseMessageChunk):
    def __add__(self, other: AIMessageChunk) -> AIMessageChunk:
        # 返回合并后的新块，不修改原块（函数式）
        return AIMessageChunk(content=self.content + other.content, ...)

# 使用示例
chunks = []
async for chunk in model.astream("Tell me a story"):
    chunks.append(chunk)
    # 实时显示
    print(chunk.content, end="", flush=True)

# 累加得到完整消息
full_message = chunks[0]
for chunk in chunks[1:]:
    full_message = full_message + chunk
```

**与 kosong 对比**：
- kosong: `merge_in_place` - 就地修改，节省内存
- LangChain: `__add__` - 函数式，创建新对象，更安全

### astream_events - 中间步骤可见性

```python
# LangChain 最强大的流式特性：中间步骤完全可见
async for event in agent.astream_events({"input": "What's the weather?"}, version="v2"):
    event_type = event["event"]
    
    match event_type:
        case "on_chain_start":
            print(f"Chain '{event['name']}' started")
            
        case "on_llm_stream":
            # LLM 实时输出
            chunk = event["data"]["chunk"]
            print(f"Token: {chunk.content}")
            
        case "on_tool_start":
            # 工具开始执行
            print(f"Tool '{event['name']}' called with {event['data']['input']}")
            
        case "on_tool_end":
            # 工具执行完成
            print(f"Tool returned: {event['data']['output']}")
            
        case "on_chain_end":
            # 链执行结束
            print(f"Final output: {event['data']['output']}")
```

**事件数据模型**：

```python
{
    "event": "on_llm_stream",           # 事件类型
    "name": "ChatOpenAI",               # 组件名称
    "run_id": "...",                    # 运行 ID
    "tags": ["..."],                    # 标签
    "metadata": {...},                  # 元数据
    "data": {
        "chunk": AIMessageChunk(...),   # 数据块
    }
}
```

### 流式一等公民指数：⭐⭐⭐⭐ (4/5)

| 维度 | 评分 | 说明 |
|------|------|------|
| API 设计 | ⭐⭐⭐⭐⭐ | Runnable 统一接口，stream/astream/astream_events |
| 数据流模式 | ⭐⭐⭐⭐⭐ | 拉模式 + 推模式（Callback）双支持 |
| 片段管理 | ⭐⭐⭐⭐ | `__add__` 累加，函数式安全 |
| 工具调用 | ⭐⭐⭐⭐⭐ | Callback 原生支持，astream_events 可见 |
| 错误处理 | ⭐⭐⭐⭐ | Callback `on_error` + 异常抛出 |
| 取消机制 | ⭐⭐⭐ | 依赖 asyncio.CancelledError |

**扣分项**：
- 学习曲线较陡（两种模式需要理解）
- astream_events 的 v1/v2 API 变动带来兼容性问题
- 包体积大，启动慢

---

## 综合对比

### 流式抽象层次

```
┌─────────────────────────────────────────────────────────────────────┐
│  litai           无抽象，直接透传 SDK 流（Iterator[str]）             │
│  ──────────────────────────────────────────────────────────────     │
│  republic        包装器模式（TextStream / StreamEvents）             │
│  ──────────────────────────────────────────────────────────────     │
│  kosong          Protocol 抽象（StreamedMessage AsyncIterator）      │
│  ──────────────────────────────────────────────────────────────     │
│  pydantic-ai     完整事件系统（StreamedResponse + PartsManager）     │
│  ──────────────────────────────────────────────────────────────     │
│  LangChain       双模式（Callback 推模式 + Iterator 拉模式）         │
└─────────────────────────────────────────────────────────────────────┘
```

### 关键能力矩阵

| 能力 | kosong | republic | litai | pydantic-ai | LangChain |
|------|--------|----------|-------|-------------|-----------|
| **流式原生支持** | ✅ Protocol | ✅ 专门类 | ⚠️ 参数切换 | ✅ ABC | ✅ Runnable |
| **异步流式** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **同步流式** | ❌ | ✅ | ✅ | ❌ | ✅ |
| **文本片段合并** | ✅ 自动 | ✅ Assembler | ❌ 无 | ✅ PartsManager | ✅ `__add__` 累加 |
| **工具调用流式** | ✅ 原生 | ⚠️ Events 模式 | ❌ 不支持 | ✅ 原生 | ✅ Callback |
| **思考内容流式** | ✅ ThinkPart | ❌ | ❌ | ✅ ThinkingPart | ✅ 元数据支持 |
| **流式取消** | ✅ | ⚠️ | ⚠️ | ✅ | ⚠️ |
| **背压控制** | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ |
| **流式错误恢复** | ❌ | ✅ State | ❌ | ✅ | ✅ Callback |
| **中间步骤可见** | ⚠️ | ✅ | ❌ | ✅ | ✅ astream_events |

### 设计哲学对比

| 框架 | 哲学 | 适用场景 |
|------|------|----------|
| **kosong** | "流式是默认" | Agent 实时交互，需要低延迟响应 |
| **republic** | "显式选择流式" | 审计优先，需要结构化事件 |
| **litai** | "简单透传" | 快速原型，不复杂的流式场景 |
| **pydantic-ai** | "结构化流式" | 复杂 Agent，需要精确控制 |
| **LangChain** | "双模式流式" | 需要推/拉双模式的灵活场景，WebSocket 推送 |

---

## 评估：谁是最好设计？

### 🏆 最佳流式设计：**kosong**

**理由**：

1. **Protocol 优于继承**：不强制类继承，任何实现协议的类都是合法 Provider
2. **合并逻辑优雅**：`merge_in_place` 机制让上层完全无感知片段分割
3. **延迟最低**：Callback 机制让应用层可以立即响应每个片段
4. **工具调用一体**：ToolCall 和 ToolCallPart 的协作设计精妙

```python
# kosong 的优雅示例
async for part in stream:
    # 文本自动合并，工具调用自动组装
    # 上层只处理完整的逻辑单元
    if isinstance(part, ToolCall):
        print(f"Tool: {part.function.name}")
```

### 🥈 最佳结构化流式：**pydantic-ai**

**理由**：

1. **事件系统完整**：PartStart → PartDelta → PartEnd → FinalResult
2. **PartsManager 专业**：统一处理不同厂商的 delta 格式
3. **类型安全**：完整的类型注解，IDE 友好

### 🥉 最佳简单流式：**litai**

**理由**：

1. **零学习成本**：就是 Python Iterator
2. **Peek 机制实用**：避免空响应的尴尬等待

### 🏅 最灵活流式：**LangChain**

**理由**：

1. **双模式支持**：Callback（推）+ Iterator（拉）满足不同场景
2. **中间步骤可见**：`astream_events` 提供完整的执行可见性
3. **生态系统丰富**：支持几百种集成，流式适配器完善

```python
# LangChain WebSocket 场景的最佳实践
class WebSocketCallbackHandler(BaseCallbackHandler):
    def on_llm_new_token(self, token: str, **kwargs):
        # 推模式：零延迟推送
        websocket.send(token)

# 同时使用拉模式处理背压
async for chunk in chain.astream(input):
    await websocket.send(chunk.content)
    await asyncio.sleep(0.01)  # 背压控制
```

---

## 流式设计反模式

### ❌ litai 的问题

```python
# 返回类型不统一！
def chat(..., stream: bool = False) -> Union[
    str,                                    # 非流式
    Task[Union[str, AsyncIterator[str]]],  # 异步
    Iterator[str],                          # 流式
    None
]:
```

**问题**：调用方需要复杂的类型判断

### ❌ republic 的问题

```python
# 两种流式 API 分裂功能
def stream(...) -> TextStream: ...           # 纯文本，无工具
def stream_events(...) -> StreamEvents: ...  # 有工具，但复杂
```

**问题**：用户需要选择 API，不能同时获得简单和完整功能

---

## 推荐方案

### 如果你需要...

| 需求 | 推荐框架 | 代码示例 |
|------|----------|----------|
| 最低延迟实时响应 | kosong | `async for part in stream: callback(part)` |
| 完整的结构化事件 | pydantic-ai | `async for event in response: handle(event)` |
| 简单文本流式 | litai | `for chunk in llm.chat(..., stream=True)` |
| 审计+流式 | republic | `for event in llm.stream_events(...)` |
| WebSocket 双模式推送 | LangChain | `CallbackHandler` + `astream()` |
| 中间步骤完全可见 | LangChain | `astream_events(version="v2")` |

---

## 相关文件

- kosong: `kimi-cli/packages/kosong/src/kosong/`
  - `_generate.py` - 流式生成核心
  - `message.py` - MergeableMixin
  - `chat_provider/kimi.py` - Provider 流式实现
  
- republic: `republic/src/republic/`
  - `clients/chat.py` - stream/stream_events 实现
  - `core/results.py` - TextStream, StreamEvents
  
- litai: `litai/src/litai/`
  - `llm.py` - 透传式流式
  
- pydantic-ai: `pydantic-ai/pydantic_ai_slim/pydantic_ai/`
  - `models/__init__.py` - StreamedResponse
  - `_parts_manager.py` - ModelResponsePartsManager

- LangChain: `langchain/libs/core/langchain_core/`
  - `runnables/base.py` - Runnable 流式方法
  - `callbacks/base.py` - CallbackHandler 基类
  - `tracers/event_stream.py` - astream_events 实现
  - `messages/ai.py` - AIMessageChunk 累加

---

*Last updated: 2026-02-25*
