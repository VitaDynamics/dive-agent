# 状态快照模式与双模并发设计

> **Related topics**: [[error-handling-retries]], [[tool-call-streaming]], [[callback-middleware]]

## Overview

状态快照模式（State Snapshot Pattern）和双模并发（Dual-Mode Concurrency）是现代 LLM 抽象层中处理状态管理和并发访问的核心设计模式。通过分析 kimi-cli (kosong)、republic 和 pydantic-ai 三个框架的实现，本文总结了这些模式的核心需求、实现方式以及对 Rust LLM 抽象层设计的启示。

## Key Concepts

### 1. 状态快照模式的核心需求

#### 1.1 为什么需要状态快照

LLM 应用中的状态管理面临以下挑战：

- **可恢复性**：长时间运行的对话需要能够保存和恢复状态
- **可观测性**：UI 需要实时反映 Agent 的内部状态变化
- **可回滚**：支持撤销操作（如 kimi-cli 的 checkpoint/revert 机制）
- **并发安全**：多个并发请求需要隔离的状态空间

#### 1.2 快照的粒度

不同框架采用不同的快照粒度：

| 框架 | 快照粒度 | 存储方式 | 特点 |
|------|----------|----------|------|
| **kimi-cli** | Checkpoint（检查点） | JSONL 文件 | 支持 revert_to 回滚到任意检查点 |
| **republic** | TapeEntry（磁带条目） | 内存/可插拔存储 | 不可变追加，支持 anchor 定位 |
| **pydantic-ai** | GraphAgentState | 内存（Graph 上下文） | 基于 pydantic_graph 的状态流转 |

### 2. kimi-cli (kosong) 的实现

#### 2.1 Context - Checkpoint 机制

kimi-cli 的 `Context` 类实现了基于文件的检查点机制：

```python
class Context:
    def __init__(self, file_backend: Path):
        self._file_backend = file_backend
        self._history: list[Message] = []
        self._token_count: int = 0
        self._next_checkpoint_id: int = 0

    async def checkpoint(self, add_user_message: bool):
        """创建检查点，写入特殊标记到文件"""
        checkpoint_id = self._next_checkpoint_id
        self._next_checkpoint_id += 1
        async with aiofiles.open(self._file_backend, "a", encoding="utf-8") as f:
            await f.write(json.dumps({"role": "_checkpoint", "id": checkpoint_id}) + "\n")

    async def revert_to(self, checkpoint_id: int):
        """回滚到指定检查点，旋转文件并重建状态"""
        # 1. 旋转当前文件（备份）
        rotated_file_path = await next_available_rotation(self._file_backend)
        await aiofiles.os.replace(self._file_backend, rotated_file_path)
        # 2. 从备份文件读取，只恢复到指定检查点之前的内容
        # 3. 重建内存状态
```

**Location**: `kimi-cli/src/kimi_cli/soul/context.py:1-166`

#### 2.2 LinearContext - 线性状态抽象

kosong 包提供了更通用的 `LinearContext` 抽象：

```python
class LinearContext:
    """A context that contains a linear history of messages."""

    def __init__(self, storage: "LinearStorage"):
        self._storage = storage

    @property
    def history(self) -> list[Message]:
        return self._storage.messages

    async def add_message(self, message: Message):
        await self._storage.append_message(message)
```

**Storage 协议设计**：

```python
@runtime_checkable
class LinearStorage(Protocol):
    @property
    def messages(self) -> list[Message]: ...
    @property
    def token_count(self) -> int: ...
    async def append_message(self, message: Message) -> None: ...
    async def mark_token_count(self, token_count: int) -> None: ...
```

**Location**: `kimi-cli/packages/kosong/src/kosong/contrib/context/linear.py:1-98`

#### 2.3 Wire - UI 状态同步通道

kimi-cli 使用 `Wire` 作为 Soul（Agent 核心）和 UI 之间的通信通道：

```python
class Wire:
    """A spmc channel for communication between the soul and the UI during a soul run."""

    def __init__(self, *, file_backend: WireFile | None = None):
        self._raw_queue = WireMessageQueue()      # 原始消息队列
        self._merged_queue = WireMessageQueue()   # 合并后的消息队列（UI 友好）
        self._soul_side = WireSoulSide(self._raw_queue, self._merged_queue)
        self._recorder = _WireRecorder(file_backend, self._merged_queue.subscribe())
```

关键设计：
- **双队列模式**：原始队列用于精确记录，合并队列用于 UI 展示
- **自动合并**：连续的内容片段自动合并，减少 UI 刷新次数
- **持久化**：可选的 `WireFile` 后端自动记录所有消息

**Location**: `kimi-cli/src/kimi_cli/wire/__init__.py:1-118`

#### 2.4 StatusSnapshot - 不可变状态快照

```python
@dataclass(frozen=True, slots=True)
class StatusSnapshot:
    context_usage: float    # 上下文使用百分比
    yolo_enabled: bool = False   # 自动批准模式
```

Soul 协议暴露 `status` 属性返回不可变快照：

```python
@runtime_checkable
class Soul(Protocol):
    @property
    def status(self) -> StatusSnapshot:
        """The current status of the soul. The returned value is immutable."""
        ...
```

**Location**: `kimi-cli/src/kimi_cli/soul/__init__.py:53-86`

### 3. republic 的实现

#### 3.1 Tape - 不可变状态磁带

republic 使用 "Tape"（磁带）隐喻来管理状态：

```python
@dataclass(frozen=True)
class TapeEntry:
    """A single append-only entry in a tape."""
    id: int
    kind: str           # message, system, anchor, tool_call, tool_result, error, event
    payload: dict[str, Any]
    meta: dict[str, Any] = field(default_factory=dict)

    def copy(self) -> TapeEntry:
        return TapeEntry(self.id, self.kind, dict(self.payload), dict(self.meta))
```

**Location**: `republic/src/republic/tape/entries.py:1-58`

#### 3.2 TapeStore - 存储抽象

```python
class TapeStore(Protocol):
    """Append-only tape storage interface."""
    def list_tapes(self) -> list[str]: ...
    def reset(self, tape: str) -> None: ...
    def read(self, tape: str) -> list[TapeEntry] | None: ...
    def append(self, tape: str, entry: TapeEntry) -> None: ...

class InMemoryTapeStore:
    """In-memory tape storage (not thread-safe)."""
    def __init__(self) -> None:
        self._tapes: dict[str, list[TapeEntry]] = {}
        self._next_id: dict[str, int] = {}
```

**Location**: `republic/src/republic/tape/store.py:1-38`

#### 3.3 TapeContext - 上下文选择

```python
@dataclass(frozen=True)
class TapeContext:
    """Rules for selecting tape entries into a prompt context."""
    anchor: AnchorSelector = LAST_ANCHOR  # 定位锚点
    select: Callable[[Sequence[TapeEntry], TapeContext], list[dict[str, Any]]] | None = None
```

**Anchor 机制**：
- `LAST_ANCHOR`：从最后一个锚点开始
- `None`：完整磁带
- `"anchor_name"`：从指定锚点开始

**Location**: `republic/src/republic/tape/context.py:1-58`

#### 3.4 TapeQuery - 声明式查询

```python
@dataclass(frozen=True)
class TapeQuery:
    tape: str
    store: TapeStore
    _after_anchor: str | None = None
    _after_last: bool = False
    _between: tuple[str, str] | None = None
    _kinds: tuple[str, ...] = field(default_factory=tuple)
    _limit: int | None = None

    def after_anchor(self, name: str) -> TapeQuery:
        """返回新的 Query，从指定锚点之后开始"""
        return TapeQuery(...)

    def kinds(self, *kinds: str) -> TapeQuery:
        """过滤特定类型的条目"""
        return TapeQuery(...)
```

**Location**: `republic/src/republic/tape/query.py:1-118`

### 4. pydantic-ai 的实现

#### 4.1 GraphAgentState - 图状态管理

pydantic-ai 基于 `pydantic_graph` 构建，状态与图执行绑定：

```python
class GraphAgentState:
    """State kept across the execution of the agent graph."""
    message_history: list[_messages.ModelMessage] = dataclasses.field(default_factory=list)
    usage: _usage.RunUsage = dataclasses.field(default_factory=_usage.RunUsage)
    retries: int = 0
    run_step: int = 0
    run_id: str = dataclasses.field(default_factory=lambda: str(uuid.uuid4()))
    metadata: dict[str, Any] | None = None
```

**Location**: `pydantic-ai/pydantic_ai_slim/pydantic_ai/_agent_graph.py:86-155`

#### 4.2 AgentRun - 状态迭代器

```python
@dataclasses.dataclass(repr=False)
class AgentRun(Generic[AgentDepsT, OutputDataT]):
    """A stateful, async-iterable run of an Agent."""
    _graph_run: GraphRun[...]

    @property
    def ctx(self) -> GraphRunContext[GraphAgentState, GraphAgentDeps[AgentDepsT, Any]]:
        """The current context of the agent run."""
        return GraphRunContext[state=self._graph_run.state, deps=self._graph_run.deps]

    def all_messages(self) -> list[_messages.ModelMessage]:
        """Return all messages for the run so far."""
        return self.ctx.state.message_history

    def new_messages(self) -> list[_messages.ModelMessage]:
        """Return new messages for the run so far (excluding old runs)."""
        return self.all_messages()[self.ctx.deps.new_message_index :]
```

**Location**: `pydantic-ai/pydantic_ai_slim/pydantic_ai/run.py:1-120`

#### 4.3 UI 状态同步 - StateHandler 协议

pydantic-ai 提供了 UI 适配器模式来处理前端状态同步：

```python
@runtime_checkable
class StateHandler(Protocol):
    """Protocol for state handlers in agent runs."""
    __dataclass_fields__: ClassVar[dict[str, Field[Any]]]

    @property
    def state(self) -> Any: ...

    @state.setter
    def state(self, state: Any) -> None: ...


@dataclass
class StateDeps(Generic[StateT]):
    """Dependency type that holds state."""
    state: StateT
```

**Location**: `pydantic-ai/pydantic_ai_slim/pydantic_ai/ui/_adapter.py:1-120`

#### 4.4 Vercel AI 状态模型

pydantic-ai 支持 Vercel AI SDK 的状态模型：

```python
class TextUIPart(BaseUIPart):
    type: Literal['text'] = 'text'
    text: str
    state: Literal['streaming', 'done'] | None = None   # 流式状态

class ToolInputStreamingPart(BaseUIPart):
    """Tool part in input-streaming state."""
    state: Literal['input-streaming'] = 'input-streaming'
    input: Any | None = None
```

**Location**: `pydantic-ai/pydantic_ai_slim/pydantic_ai/ui/vercel_ai/request_types.py:1-300`

### 5. 双模并发：同步 vs 异步 API 的统一

#### 5.1 republic 的双模实现

republic 在 `LLMCore` 中实现了统一的同步/异步执行：

```python
class LLMCore:
    """Shared LLM execution utilities."""

    def run_chat_sync(
        self,
        *,
        messages_payload: list[dict[str, Any]],
        tools_payload: list[dict[str, Any]] | None,
        # ...
        on_response: Callable[[Any, str, str, int], Any],
    ) -> Any:
        """同步执行，使用 client.completion"""
        for provider_name, model_id, client in self.iter_clients(model, provider):
            for attempt in range(self.max_attempts()):
                try:
                    response = client.completion(...)  # 同步调用
                except Exception as exc:
                    # 错误处理和重试逻辑
                    ...

    async def run_chat_async(
        self,
        *,
        messages_payload: list[dict[str, Any]],
        tools_payload: list[dict[str, Any]] | None,
        # ...
        on_response: Callable[[Any, str, str, int], Any],
    ) -> Any:
        """异步执行，使用 client.acompletion"""
        for provider_name, model_id, client in self.iter_clients(model, provider):
            for attempt in range(self.max_attempts()):
                try:
                    response = await client.acompletion(...)  # 异步调用
                except Exception as exc:
                    # 相同的错误处理逻辑
                    ...
                else:
                    result = on_response(response, provider_name, model_id, attempt)
                    if inspect.isawaitable(result):
                        result = await result  # 自动 await 回调结果
```

**关键设计**：
- 同步和异步方法共享相同的重试和错误处理逻辑
- 回调函数可以返回可等待对象，自动处理
- 通过 `any_llm` 库的 `completion`/`acompletion` 实现底层双模

**Location**: `republic/src/republic/core/execution.py:200-350`

#### 5.2 流式 API 的双模

```python
class LLM:
    """Developer-first LLM client."""

    def stream(self, ...) -> TextStream:
        """同步流式返回"""
        return self._chat_client.stream(...)

    async def stream_async(self, ...) -> AsyncTextStream:
        """异步流式返回"""
        return await self._chat_client.stream_async(...)

    def stream_events(self, ...) -> StreamEvents:
        """同步事件流"""
        return self._chat_client.stream_events(...)

    async def stream_events_async(self, ...) -> AsyncStreamEvents:
        """异步事件流"""
        return await self._chat_client.stream_events_async(...)
```

**Location**: `republic/src/republic/llm.py:1-300`

#### 5.3 Tape 的双模访问

```python
class Tape:
    """A scoped LLM session that interacts with a specific tape."""

    def chat(self, ...) -> str:
        return self._llm.chat(..., tape=self._name, context=self.context)

    async def chat_async(self, ...) -> str:
        return await self._llm.chat_async(..., tape=self._name, context=self.context)

    def stream(self, ...) -> TextStream:
        return self._llm.stream(..., tape=self._name, context=self.context)

    async def stream_async(self, ...) -> AsyncTextStream:
        return await self._llm.stream_async(..., tape=self._name, context=self.context)
```

**Location**: `republic/src/republic/tape/session.py:1-200`

### 6. UI 状态同步友好的设计

#### 6.1 消息合并模式

kimi-cli 的 `WireSoulSide` 自动合并连续的消息片段：

```python
class WireSoulSide:
    def send(self, msg: WireMessage) -> None:
        # 发送原始消息
        self._raw_queue.publish_nowait(msg)

        # 合并并发送
        match msg:
            case MergeableMixin():
                if self._merge_buffer is None:
                    self._merge_buffer = copy.deepcopy(msg)
                elif self._merge_buffer.merge_in_place(msg):
                    pass  # 成功合并
                else:
                    self.flush()  # 无法合并，先刷新缓冲区
                    self._merge_buffer = copy.deepcopy(msg)
            case _:
                self.flush()
                self._send_merged(msg)
```

**Location**: `kimi-cli/src/kimi_cli/wire/__init__.py:50-85`

#### 6.2 流式状态标记

pydantic-ai 的 Vercel AI 适配器使用状态标记：

```python
# 文本片段状态
class TextUIPart(BaseUIPart):
    state: Literal['streaming', 'done'] | None = None

# 工具调用状态机
class ToolInputStreamingPart(BaseUIPart):
    state: Literal['input-streaming'] = 'input-streaming'

class ToolInputAvailablePart(BaseUIPart):
    state: Literal['input-available'] = 'input-available'

class ToolOutputAvailablePart(BaseUIPart):
    state: Literal['output-available'] = 'output-available'
```

**Location**: `pydantic-ai/pydantic_ai_slim/pydantic_ai/ui/vercel_ai/request_types.py:30-200`

#### 6.3 广播队列模式

kimi-cli 使用广播队列实现多 UI 订阅：

```python
WireMessageQueue = BroadcastQueue[WireMessage]

class Wire:
    def __init__(self):
        self._raw_queue = WireMessageQueue()
        self._merged_queue = WireMessageQueue()

    def ui_side(self, *, merge: bool) -> WireUISide:
        """创建 UI 侧，可以选择订阅原始或合并队列"""
        if merge:
            return WireUISide(self._merged_queue.subscribe())
        else:
            return WireUISide(self._raw_queue.subscribe())
```

## Design Decisions

### 1. 不可变状态 vs 可变状态

| 框架 | 策略 | 权衡 |
|------|------|------|
| **kimi-cli** | 可变状态 + 检查点 | 性能好，回滚复杂 |
| **republic** | 不可变追加（Tape） | 天然支持历史查询，内存占用大 |
| **pydantic-ai** | 可变状态（Graph） | 与图执行模型契合，需要 careful 设计 |

### 2. 存储抽象层级

- **kosong/LinearStorage**：底层存储协议，关注消息持久化
- **kimi-cli/Context**：业务层封装，关注检查点和回滚
- **republic/TapeStore**：领域抽象，关注不可变历史

### 3. 双模并发的实现策略

1. **代码复用**：republic 通过提取 `LLMCore` 共享同步/异步逻辑
2. **类型区分**：使用 `TextStream`/`AsyncTextStream` 明确区分返回类型
3. **自动适配**：回调函数返回可等待对象时自动 await

### 4. UI 同步的性能优化

- **消息合并**：减少 UI 刷新频率
- **双队列**：原始队列用于记录，合并队列用于展示
- **懒加载**：TapeQuery 支持延迟切片和过滤

## Code Examples

### 示例 1：kimi-cli Checkpoint 使用

```python
# 创建检查点
await context.checkpoint(add_user_message=True)

# 回滚到指定检查点
await context.revert_to(checkpoint_id=2)

# 清空上下文
await context.clear()
```

**Location**: `kimi-cli/src/kimi_cli/soul/context.py:60-140`

### 示例 2：republic Tape 查询

```python
# 创建 TapeManager
manager = TapeManager(store=InMemoryTapeStore())

# 查询特定锚点之后的消息
entries = manager.query_tape("my_tape") \
    .after_anchor("user_turn_1") \
    .kinds("message", "tool_call") \
    .limit(10) \
    .all()

# 在两个锚点之间查询
entries = manager.query_tape("my_tape") \
    .between_anchors("start", "end") \
    .all()
```

**Location**: `republic/src/republic/tape/query.py:20-118`

### 示例 3：pydantic-ai AgentRun 迭代

```python
async with agent.iter('What is the capital of France?') as agent_run:
    async for node in agent_run:
        print(f"Executing: {type(node).__name__}")
        # 可以在这里检查/修改节点状态

    print(f"Result: {agent_run.result.output}")
    print(f"Usage: {agent_run.usage()}")
```

**Location**: `pydantic-ai/pydantic_ai_slim/pydantic_ai/run.py:30-120`

### 示例 4：双模 API 调用

```python
llm = LLM(model="openai:gpt-4")

# 同步调用
response = llm.chat("Hello!")

# 异步调用
response = await llm.chat_async("Hello!")

# 同步流式
for chunk in llm.stream("Tell me a story"):
    print(chunk, end="")

# 异步流式
async for chunk in await llm.stream_async("Tell me a story"):
    print(chunk, end="")
```

**Location**: `republic/src/republic/llm.py:80-200`

## 对 Rust LLM 抽象层设计的启示

### 1. 状态快照设计

```rust
// 不可变状态快照 trait
pub trait StateSnapshot: Clone + Send + Sync {
    fn snapshot(&self) -> Self;
    fn restore(&mut self, snapshot: &Self);
}

// 检查点管理器
pub struct CheckpointManager<S: StateSnapshot> {
    snapshots: Vec<S>,
    current: S,
}

impl<S: StateSnapshot> CheckpointManager<S> {
    pub fn checkpoint(&mut self) -> usize {
        self.snapshots.push(self.current.snapshot());
        self.snapshots.len() - 1
    }

    pub fn revert_to(&mut self, id: usize) -> Result<(), Error> {
        if id >= self.snapshots.len() {
            return Err(Error::CheckpointNotFound);
        }
        self.current.restore(&self.snapshots[id]);
        self.snapshots.truncate(id + 1);
        Ok(())
    }
}
```

### 2. 双模并发设计

```rust
// 统一的执行 trait
#[async_trait]
pub trait ChatProvider {
    // 同步方法
    fn generate_sync(&self, request: Request) -> Result<Response, Error>;

    // 异步方法
    async fn generate_async(&self, request: Request) -> Result<Response, Error>;

    // 流式方法
    fn stream_sync(&self, request: Request) -> Box<dyn Iterator<Item = Chunk>>;
    async fn stream_async(&self, request: Request) -> Box<dyn Stream<Item = Chunk>>;
}

// 使用 tokio::task::spawn_blocking 实现同步包装
pub fn generate_sync(&self, request: Request) -> Result<Response, Error> {
    let provider = self.clone();
    tokio::task::block_in_place(|| {
        tokio::runtime::Handle::current().block_on(provider.generate_async(request))
    })
}
```

### 3. UI 状态同步设计

```rust
// 消息合并 trait
pub trait Mergeable: Clone {
    fn can_merge_with(&self, other: &Self) -> bool;
    fn merge_in_place(&mut self, other: Self) -> bool;
}

// 广播通道
pub struct BroadcastChannel<T: Clone> {
    subscribers: Vec<mpsc::UnboundedSender<T>>,
}

impl<T: Clone> BroadcastChannel<T> {
    pub fn subscribe(&self) -> mpsc::UnboundedReceiver<T> {
        let (tx, rx) = mpsc::unbounded_channel();
        self.subscribers.push(tx);
        rx
    }

    pub fn broadcast(&self, msg: T) {
        for subscriber in &self.subscribers {
            let _ = subscriber.send(msg.clone());
        }
    }
}

// 合并缓冲区
pub struct MergingBuffer<T: Mergeable> {
    buffer: Option<T>,
}

impl<T: Mergeable> MergingBuffer<T> {
    pub fn push(&mut self, item: T) -> Option<T> {
        match &mut self.buffer {
            Some(buffer) => {
                if buffer.can_merge_with(&item) {
                    buffer.merge_in_place(item);
                    None
                } else {
                    self.buffer.replace(item)
                }
            }
            None => {
                self.buffer = Some(item);
                None
            }
        }
    }

    pub fn flush(&mut self) -> Option<T> {
        self.buffer.take()
    }
}
```

### 4. Tape 模式实现

```rust
// 磁带条目
#[derive(Clone, Debug)]
pub struct TapeEntry {
    pub id: u64,
    pub kind: EntryKind,
    pub payload: serde_json::Value,
    pub meta: HashMap<String, serde_json::Value>,
}

#[derive(Clone, Copy, Debug)]
pub enum EntryKind {
    Message,
    System,
    Anchor,
    ToolCall,
    ToolResult,
    Error,
    Event,
}

// 磁带存储 trait
#[async_trait]
pub trait TapeStore: Send + Sync {
    async fn append(&self, tape: &str, entry: TapeEntry) -> Result<u64, Error>;
    async fn read(&self, tape: &str) -> Result<Vec<TapeEntry>, Error>;
    async fn reset(&self, tape: &str) -> Result<(), Error>;
}

// 查询构建器
pub struct TapeQuery<'a> {
    store: &'a dyn TapeStore,
    tape: String,
    after_anchor: Option<String>,
    kinds: Vec<EntryKind>,
    limit: Option<usize>,
}

impl<'a> TapeQuery<'a> {
    pub fn after_anchor(mut self, name: impl Into<String>) -> Self {
        self.after_anchor = Some(name.into());
        self
    }

    pub fn kinds(mut self, kinds: Vec<EntryKind>) -> Self {
        self.kinds = kinds;
        self
    }

    pub async fn execute(self) -> Result<Vec<TapeEntry>, Error> {
        let entries = self.store.read(&self.tape).await?;
        // 应用过滤逻辑
        Ok(entries)
    }
}
```

## Related Files

- `kimi-cli/src/kimi_cli/soul/context.py` - Checkpoint 机制实现
- `kimi-cli/packages/kosong/src/kosong/contrib/context/linear.py` - LinearContext 抽象
- `kimi-cli/src/kimi_cli/wire/__init__.py` - Wire 通信通道
- `kimi-cli/src/kimi_cli/soul/__init__.py` - Soul 协议和 StatusSnapshot
- `republic/src/republic/tape/entries.py` - TapeEntry 定义
- `republic/src/republic/tape/store.py` - TapeStore 协议和实现
- `republic/src/republic/tape/query.py` - TapeQuery 查询构建器
- `republic/src/republic/tape/context.py` - TapeContext 上下文选择
- `republic/src/republic/core/execution.py` - LLMCore 双模执行
- `pydantic-ai/pydantic_ai_slim/pydantic_ai/_agent_graph.py` - GraphAgentState
- `pydantic-ai/pydantic_ai_slim/pydantic_ai/run.py` - AgentRun 状态迭代
- `pydantic-ai/pydantic_ai_slim/pydantic_ai/ui/_adapter.py` - UI 适配器基类
- `pydantic-ai/pydantic_ai_slim/pydantic_ai/ui/vercel_ai/request_types.py` - Vercel AI 状态模型

---
*Last updated: 2026-02-26*
