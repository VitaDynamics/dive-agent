# LLM 框架上下文管理双模式设计研究

## 概述

本文研究 5 个主流 LLM 框架的上下文管理机制，重点分析**审计模式**（完整历史保留）与**节省 Token 模式**（历史压缩/截断）的双模式设计实现。

研究框架：
1. **kimi-cli (kosong)** - Moonshot AI 的 CLI 框架
2. **langchain** - 最流行的 LLM 应用框架
3. **litai** - Lightning AI 的 LLM 客户端
4. **pydantic-ai** - Pydantic 的 AI 代理框架
5. **republic** - 轻量级 LLM 交互框架

---

## 1. 架构设计对比

### 1.1 核心抽象对比

| 框架 | 历史管理核心类 | 消息类型 | 存储抽象 |
|------|---------------|---------|---------|
| **kimi-cli** | `LinearContext` + `LinearStorage` | `Message` + `ContentPart` | `LinearStorage` Protocol |
| **langchain** | `BaseChatMessageHistory` | `BaseMessage` | `BaseChatMessageHistory` ABC |
| **litai** | `SDKLLM` 内置 | `dict` 格式 | 底层 SDK 管理 |
| **pydantic-ai** | `GraphAgentState` | `ModelMessage` dataclass | 内存 + TypeAdapter 序列化 |
| **republic** | `TapeManager` + `TapeStore` | `TapeEntry` | `TapeStore` Protocol |

### 1.2 双模式设计概览

```
┌─────────────────────────────────────────────────────────────────┐
│                      上下文管理双模式架构                        │
├─────────────────────────────────────────────────────────────────┤
│  审计模式 (Audit Mode)          │  节省 Token 模式 (Token Mode)  │
│  ─────────────────────          │  ────────────────────────────  │
│  • 完整消息历史保留              │  • 历史截断/压缩               │
│  • 支持回放和调试                │  • 智能摘要                    │
│  • 持久化存储                    │  • 选择性上下文                │
│  • 审计追踪                      │  • Token 预算管理              │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. 各框架详细分析

### 2.1 kimi-cli (kosong)

#### 审计模式实现

**核心组件：**
```python
# packages/kosong/src/kosong/contrib/context/linear.py
class LinearContext:
    def __init__(self, storage: "LinearStorage"):
        self._storage = storage
    
    @property
    def history(self) -> list[Message]:
        return self._storage.messages

class JsonlLinearStorage(MemoryLinearStorage):
    """JSONL 文件持久化存储 - 审计模式核心"""
    def __init__(self, path: Path | str):
        super().__init__()
        self._path = path if isinstance(path, Path) else Path(path)
    
    async def append_message(self, message: Message):
        await super().append_message(message)
        # 追加写入 JSONL 文件
        def _write():
            file = self._get_file()
            json.dump(message.model_dump(exclude_none=True), file)
            file.write("\n")
        await asyncio.to_thread(_write)
```

**Checkpoint 机制（审计增强）：**
```python
# src/kimi_cli/soul/context.py
class Context:
    async def checkpoint(self, add_user_message: bool):
        """创建检查点用于审计回放"""
        checkpoint_id = self._next_checkpoint_id
        self._next_checkpoint_id += 1
        # 写入检查点标记
        async with aiofiles.open(self._file_backend, "a") as f:
            await f.write(json.dumps({"role": "_checkpoint", "id": checkpoint_id}) + "\n")
    
    async def revert_to(self, checkpoint_id: int):
        """回滚到指定检查点 - 审计模式的关键能力"""
        # 文件旋转 + 历史恢复
        await aiofiles.os.replace(self._file_backend, rotated_file_path)
        # 重建历史直到指定检查点
```

#### 节省 Token 模式实现

**Compaction（压缩）机制：**
```python
# src/kimi_cli/soul/compaction.py
@runtime_checkable
class Compaction(Protocol):
    async def compact(self, messages: Sequence[Message], llm: LLM) -> Sequence[Message]:
        """将消息序列压缩成新的序列"""

class SimpleCompaction:
    def __init__(self, max_preserved_messages: int = 2):
        self.max_preserved_messages = max_preserved_messages
    
    async def compact(self, messages: Sequence[Message], llm: LLM) -> Sequence[Message]:
        compact_message, to_preserve = self.prepare(messages)
        # 使用 LLM 压缩历史上下文
        result = await kosong.step(
            chat_provider=llm.chat_provider,
            system_prompt="You are a helpful assistant that compacts conversation context.",
            history=[compact_message],
        )
        # 生成压缩后的摘要消息
        content = [system("Previous context has been compacted. Here is the compaction output:")]
        content.extend(part for part in result.message.content if not isinstance(part, ThinkPart))
        return [Message(role="user", content=content)] + list(to_preserve)
```

**Wire 协议事件（双模式切换信号）：**
```python
# src/kimi_cli/wire/types.py
class CompactionBegin(BaseModel):
    """压缩开始事件 - Token 优化模式触发"""
    pass

class CompactionEnd(BaseModel):
    """压缩结束事件"""
    pass

class StatusUpdate(BaseModel):
    """上下文使用率更新"""
    context_usage: float | None = None  # 上下文使用率百分比
    token_usage: TokenUsage | None = None
```

#### 存储策略对比

| 存储类型 | 审计模式 | Token 优化 | 适用场景 |
|---------|---------|-----------|---------|
| `MemoryLinearStorage` | 内存存储，进程结束丢失 | 支持 | 测试/临时会话 |
| `JsonlLinearStorage` | JSONL 文件持久化 | 支持 | 生产环境审计 |

---

### 2.2 LangChain

#### 审计模式实现

**BaseChatMessageHistory 抽象：**
```python
# libs/core/langchain_core/chat_history.py
class BaseChatMessageHistory(ABC):
    """聊天消息历史的抽象基类 - 审计模式基础"""
    
    messages: list[BaseMessage]
    
    def add_messages(self, messages: Sequence[BaseMessage]) -> None:
        """批量添加消息 - 审计记录"""
        for message in messages:
            self.add_message(message)
    
    @abstractmethod
    def clear(self) -> None:
        """清除所有消息"""

class InMemoryChatMessageHistory(BaseChatMessageHistory, BaseModel):
    """内存实现 - 基础审计"""
    messages: list[BaseMessage] = Field(default_factory=list)
```

**Tracer 追踪系统（深度审计）：**
```python
# libs/core/langchain_core/tracers/base.py
class BaseTracer(_TracerCore, BaseCallbackHandler, ABC):
    """追踪器基类 - 完整执行审计"""
    
    def _start_trace(self, run: Run) -> None:
        """开始追踪运行"""
        super()._start_trace(run)
        self._on_run_create(run)
    
    def _end_trace(self, run: Run) -> None:
        """结束追踪并持久化"""
        if not run.parent_run_id:
            self._persist_run(run)  # 持久化运行记录
        self.run_map.pop(str(run.id))
```

#### 节省 Token 模式实现

**RunnableWithMessageHistory（Token 优化包装器）：**
```python
# libs/core/langchain_core/runnables/history.py
class RunnableWithMessageHistory(RunnableBindingBase):
    """带消息历史管理的 Runnable - 双模式切换入口"""
    
    get_session_history: GetSessionHistoryCallable
    input_messages_key: str | None = None
    output_messages_key: str | None = None
    history_messages_key: str | None = None
    history_factory_config: Sequence[ConfigurableFieldSpec]
    
    def _enter_history(self, value: Any, config: RunnableConfig) -> list[BaseMessage]:
        """进入历史 - 可插入 Token 优化逻辑"""
        hist: BaseChatMessageHistory = config["configurable"]["message_history"]
        messages = hist.messages.copy()
        if not self.history_messages_key:
            input_val = value if not self.input_messages_key else value[self.input_messages_key]
            messages += self._get_input_messages(input_val)
        return messages
```

**Token 优化策略（用户自定义）：**
```python
# 典型的 Token 优化配置示例
def get_session_history(session_id: str) -> BaseChatMessageHistory:
    """可返回带截断逻辑的历史存储"""
    store = RedisChatMessageHistory(session_id)
    # 可在此处实现 Token 预算检查
    return store

# 使用配置字段控制历史长度
history_factory_config = [
    ConfigurableFieldSpec(
        id="max_history_length",
        annotation=int,
        name="Max History Length",
        description="Maximum number of messages to keep",
        default=10,
    ),
]
```

#### 双模式切换机制

```python
# 审计模式配置（完整历史）
audit_config = {"configurable": {"session_id": "audit-session"}}

# Token 优化模式配置（截断历史）
token_opt_config = {
    "configurable": {
        "session_id": "token-opt-session",
        "max_history_length": 5,  # 限制历史长度
    }
}

# 运行时切换
with_history.invoke(input, config=audit_config)      # 审计模式
with_history.invoke(input, config=token_opt_config)  # Token 优化模式
```

---

### 2.3 pydantic-ai

#### 审计模式实现

**GraphAgentState（完整状态）：**
```python
# pydantic_ai_slim/pydantic_ai/_agent_graph.py
@dataclasses.dataclass(kw_only=True)
class GraphAgentState:
    """代理图执行状态 - 审计模式核心"""
    
    message_history: list[_messages.ModelMessage] = dataclasses.field(
        default_factory=list[_messages.ModelMessage]
    )
    usage: _usage.RunUsage = dataclasses.field(default_factory=_usage.RunUsage)
    retries: int = 0
    run_step: int = 0
    run_id: str = dataclasses.field(default_factory=lambda: str(uuid.uuid4()))
    metadata: dict[str, Any] | None = None
```

**消息序列化（审计持久化）：**
```python
# pydantic_ai/messages.py 中的 ModelMessagesTypeAdapter
ModelMessagesTypeAdapter = TypeAdapter(list[ModelMessage])

# 审计持久化示例
history_step_1 = result1.all_messages()
as_python_objects = to_jsonable_python(history_step_1)
# 存储到数据库/文件
same_history = ModelMessagesTypeAdapter.validate_python(as_python_objects)
```

#### 节省 Token 模式实现

**HistoryProcessor（Token 优化处理器）：**
```python
# pydantic_ai_slim/pydantic_ai/_agent_graph.py
HistoryProcessor = (
    _HistoryProcessorSync
    | _HistoryProcessorAsync
    | _HistoryProcessorSyncWithCtx[DepsT]
    | _HistoryProcessorAsyncWithCtx[DepsT]
)
"""可拦截并修改消息历史的处理器 - Token 优化入口"""

async def _process_message_history(
    messages: list[_messages.ModelMessage],
    processors: Sequence[HistoryProcessor[DepsT]],
    run_context: RunContext[DepsT],
) -> list[_messages.ModelMessage]:
    """通过处理器链处理消息历史"""
    for processor in processors:
        # 支持同步/异步、带/不带上下文
        if is_async_callable(processor):
            messages = await processor(messages)
        else:
            messages = await run_in_executor(processor, messages)
    return messages
```

**典型 Token 优化处理器：**

```python
# 1. 截断处理器（保留最近 N 条）
async def keep_recent_messages(messages: list[ModelMessage]) -> list[ModelMessage]:
    """Keep only the last 5 messages to manage token usage."""
    return messages[-5:] if len(messages) > 5 else messages

# 2. 摘要处理器（LLM 压缩历史）
async def summarize_old_messages(messages: list[ModelMessage]) -> list[ModelMessage]:
    """使用 cheaper model 摘要旧消息"""
    if len(messages) > 10:
        oldest_messages = messages[:10]
        summary = await summarize_agent.run(message_history=oldest_messages)
        return summary.new_messages() + messages[-1:]
    return messages

# 3. 过滤处理器（选择性保留）
def filter_responses(messages: list[ModelMessage]) -> list[ModelMessage]:
    """仅保留 ModelRequest（用户输入）"""
    return [msg for msg in messages if isinstance(msg, ModelRequest)]

# 4. 上下文感知处理器
def context_aware_processor(
    ctx: RunContext[None], 
    messages: list[ModelMessage]
) -> list[ModelMessage]:
    """基于当前 Token 使用量动态调整"""
    current_tokens = ctx.usage.total_tokens
    if current_tokens > 1000:
        return messages[-3:]  # Token 使用高时仅保留最近 3 条
    return messages
```

#### 双模式配置示例

```python
# 审计模式（无处理器）
audit_agent = Agent('openai:gpt-4')

# Token 优化模式（配置处理器链）
token_opt_agent = Agent(
    'openai:gpt-4',
    history_processors=[
        filter_responses,        # 第 1 步：过滤
        keep_recent_messages,    # 第 2 步：截断
        summarize_old_messages,  # 第 3 步：摘要
    ]
)
```

---

### 2.4 republic

#### 审计模式实现

**Tape 追加存储模型：**
```python
# src/republic/tape/store.py
class TapeStore(Protocol):
    """追加式 Tape 存储协议 - 审计模式核心"""
    
    def list_tapes(self) -> list[str]: ...
    def reset(self, tape: str) -> None: ...
    def read(self, tape: str) -> list[TapeEntry] | None: ...
    def append(self, tape: str, entry: TapeEntry) -> None: ...

class InMemoryTapeStore:
    """内存实现 - 不可变条目复制"""
    def read(self, tape: str) -> list[TapeEntry] | None:
        entries = self._tapes.get(tape)
        return [entry.copy() for entry in entries] if entries else None
    
    def append(self, tape: str, entry: TapeEntry) -> None:
        next_id = self._next_id.get(tape, 1)
        self._next_id[tape] = next_id + 1
        # 创建副本存储，保证不可变性
        stored = TapeEntry(next_id, entry.kind, dict(entry.payload), dict(entry.meta))
        self._tapes.setdefault(tape, []).append(stored)
```

**TapeEntry 审计条目：**
```python
# src/republic/tape/entries.py
@dataclass(frozen=True)
class TapeEntry:
    """不可变的审计条目"""
    id: int
    kind: str  # message, system, anchor, tool_call, tool_result, error, event
    payload: dict[str, Any]
    meta: dict[str, Any] = field(default_factory=dict)
    
    @classmethod
    def message(cls, message: dict[str, Any], **meta) -> TapeEntry:
        return cls(id=0, kind="message", payload=dict(message), meta=dict(meta))
    
    @classmethod
    def anchor(cls, name: str, state: dict | None = None, **meta) -> TapeEntry:
        """锚点条目 - 用于上下文切片"""
        payload = {"name": name}
        if state is not None:
            payload["state"] = dict(state)
        return cls(id=0, kind="anchor", payload=payload, meta=dict(meta))
```

#### 节省 Token 模式实现

**TapeContext（上下文选择器）：**
```python
# src/republic/tape/context.py
@dataclass(frozen=True)
class TapeContext:
    """Tape 上下文选择规则 - Token 优化配置"""
    
    anchor: AnchorSelector = LAST_ANCHOR
    """LAST_ANCHOR: 最近锚点, None: 完整 Tape, str: 指定锚点"""
    
    select: Callable[[Sequence[TapeEntry], TapeContext], list[dict]] | None = None
    """可选的自定义选择器函数"""

def build_messages(entries: Sequence[TapeEntry], context: TapeContext) -> list[dict]:
    """根据上下文规则构建消息列表"""
    selected_entries = _slice_after_anchor(entries, context.anchor)
    if context.select is not None:
        return context.select(selected_entries, context)
    return _default_messages(selected_entries)

def _slice_after_anchor(entries: Sequence[TapeEntry], anchor: AnchorSelector) -> Sequence[TapeEntry]:
    """基于锚点切片 - Token 优化核心"""
    if anchor is None:
        return entries  # 审计模式：返回全部
    
    anchor_name = None if anchor is LAST_ANCHOR else anchor
    # 从后向前查找锚点
    for idx in range(len(entries) - 1, -1, -1):
        entry = entries[idx]
        if entry.kind == "anchor":
            if anchor_name is None or entry.payload.get("name") == anchor_name:
                return entries[idx + 1:]  # Token 优化：仅返回锚点后
    
    raise ErrorPayload(ErrorKind.NOT_FOUND, f"Anchor '{anchor_name}' not found")
```

#### 双模式使用示例

```python
# 审计模式（完整 Tape）
audit_context = TapeContext(anchor=None)
tape.chat("Hello", context=audit_context)  # 使用完整历史

# Token 优化模式（从最近锚点开始）
token_opt_context = TapeContext(anchor=LAST_ANCHOR)
tape.chat("Hello", context=token_opt_context)  # 仅使用锚点后历史

# 自定义 Token 优化（自定义选择器）
def custom_selector(entries: Sequence[TapeEntry], ctx: TapeContext) -> list[dict]:
    """仅保留最近 5 条消息"""
    messages = _default_messages(entries)
    return messages[-5:]

custom_context = TapeContext(
    anchor=LAST_ANCHOR,
    select=custom_selector
)
```

---

### 2.5 litai

#### 上下文管理设计

**会话历史管理：**
```python
# src/litai/llm.py
class LLM:
    def chat(
        self,
        prompt: str,
        conversation: Optional[str] = None,  # 会话 ID
        # ...
    ) -> Union[str, Task, Iterator[str], None]:
        """发送消息，可选 conversation ID 维持上下文"""
        
    def reset_conversation(self, name: str) -> None:
        """重置指定会话历史"""
        
    def get_history(self, name: str, raw: bool = False) -> Optional[List[Dict[str, str]]]:
        """获取会话历史 - 审计接口"""
        
    def list_conversations(self) -> List[str]:
        """列出所有会话"""
```

**设计特点：**
- litai 的上下文管理相对简单，依赖底层 `SDKLLM` 实现
- 主要通过 `conversation` 参数标识会话
- 历史管理由服务端或底层 SDK 处理
- **双模式支持较弱**，主要依赖外部配置

---

## 3. 双模式设计模式总结

### 3.1 审计模式核心要素

| 要素 | kimi-cli | langchain | pydantic-ai | republic | litai |
|-----|----------|-----------|-------------|----------|-------|
| **完整存储** | JSONL 追加 | BaseChatMessageHistory | GraphAgentState | TapeStore (追加) | SDK 依赖 |
| **不可变性** | 文件追加 | 可选 | State 拷贝 | Entry.copy() | - |
| **检查点** | checkpoint/revert | - | run_id | anchor | - |
| **持久化** | 文件 | 可插拔 | TypeAdapter | Protocol | - |
| **回放能力** | revert_to | - | message_history | 锚点切片 | get_history |

### 3.2 节省 Token 模式核心策略

| 策略 | kimi-cli | langchain | pydantic-ai | republic |
|-----|----------|-----------|-------------|----------|
| **截断** | max_preserved_messages | history_factory_config | keep_recent | anchor 切片 |
| **摘要** | LLM Compaction | 自定义 | summarize_old | custom select |
| **过滤** | - | 自定义 | filter_responses | _default_messages |
| **预算感知** | context_usage | - | context_aware | - |
| **动态切换** | CompactionBegin/End | config 切换 | 处理器链 | TapeContext 替换 |

### 3.3 存储策略对比

```
┌────────────────────────────────────────────────────────────────┐
│                      存储策略谱系                                │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  内存存储 ◄────────────────────────────────────► 持久化存储       │
│     │                                               │          │
│     ├── kim-cli/MemoryLinearStorage                 ├── kim-cli/JsonlLinearStorage
│     ├── langchain/InMemoryChatMessageHistory        ├── langchain/FileChatMessageHistory  
│     ├── pydantic-ai/内存 State                      ├── pydantic-ai/TypeAdapter
│     └── republic/InMemoryTapeStore                  └── (可扩展实现)
│                                                                │
│  特点: 快速/易失                    特点: 可靠/审计/可回放          │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

---

## 4. 性能权衡分析

### 4.1 审计模式开销

| 开销类型 | 描述 | 缓解策略 |
|---------|------|---------|
| **存储成本** | 完整历史占用磁盘/内存 | 定期归档、压缩旧历史 |
| **I/O 延迟** | 持久化写入延迟 | 异步写入、批量刷新 |
| **Token 成本** | 完整历史导致高额 API 费用 | 双模式动态切换 |
| **查询性能** | 长历史查询变慢 | 索引、缓存最近历史 |

### 4.2 Token 优化模式权衡

| 优化策略 | Token 节省 | 信息损失 | 适用场景 |
|---------|-----------|---------|---------|
| **截断** | 高 | 高（丢失早期上下文） | 短会话、独立查询 |
| **摘要** | 中高 | 中（细节丢失） | 长会话、需要概要 |
| **过滤** | 中 | 低（选择性保留） | 敏感信息过滤 |
| **锚点切片** | 可调 | 可控 | 多阶段任务 |

### 4.3 运行时切换成本

```python
# 运行时切换示例对比

# kimi-cli: 通过事件触发（低成本）
# CompactionBegin -> 压缩 -> CompactionEnd

# langchain: 配置切换（中成本）
# 需要重新构建 RunnableWithMessageHistory

# pydantic-ai: 处理器动态调整（低成本）
# 通过 RunContext 动态调整处理器行为

# republic: TapeContext 切换（低成本）
# 纯配置对象替换
```

---

## 5. 最佳实践建议

### 5.1 框架选择建议

| 场景 | 推荐框架 | 理由 |
|-----|---------|------|
| 强审计需求 | kimi-cli, republic | 内置 checkpoint/anchor 机制 |
| 灵活 Token 优化 | pydantic-ai | history_processors 链式处理 |
| 企业级应用 | langchain | 成熟的生态和存储集成 |
| 快速原型 | litai | 简单直接 |
| 工作流编排 | pydantic-ai | Graph 架构适合复杂流程 |

### 5.2 双模式实施建议

1. **默认 Token 优化，异常时切审计**
   ```python
   # 正常运行：Token 优化
   agent = Agent(model, history_processors=[keep_recent])
   
   # 调试/异常：切换审计模式
   debug_agent = Agent(model)  # 无处理器 = 完整历史
   ```

2. **分层存储策略**
   ```
   热数据（最近 10 轮）→ 内存
   温数据（最近 100 轮）→ 本地 JSONL
   冷数据（历史全部）→ 对象存储/数据库
   ```

3. **Token 预算管理**
   ```python
   def token_budget_processor(
       ctx: RunContext,
       messages: list[ModelMessage]
   ) -> list[ModelMessage]:
       total_tokens = ctx.usage.total_tokens
       budget = ctx.deps.token_budget
       
       if total_tokens > budget * 0.8:
           return summarize_and_truncate(messages)
       elif total_tokens > budget * 0.5:
           return truncate_old(messages)
       return messages
   ```

---

## 6. 参考文档

- [kimi-cli context.py](/Users/dylan/DylanLi/repo/agent-group/infra-LLM /kimi-cli/src/kimi_cli/soul/context.py)
- [kimi-cli compaction.py](/Users/dylan/DylanLi/repo/agent-group/infra-LLM /kimi-cli/src/kimi_cli/soul/compaction.py)
- [langchain chat_history.py](/Users/dylan/DylanLi/repo/agent-group/infra-LLM /langchain/libs/core/langchain_core/chat_history.py)
- [langchain history.py](/Users/dylan/DylanLi/repo/agent-group/infra-LLM /langchain/libs/core/langchain_core/runnables/history.py)
- [pydantic-ai _agent_graph.py](/Users/dylan/DylanLi/repo/agent-group/infra-LLM /pydantic-ai/pydantic_ai_slim/pydantic_ai/_agent_graph.py)
- [pydantic-ai message-history.md](/Users/dylan/DylanLi/repo/agent-group/infra-LLM /pydantic-ai/docs/message-history.md)
- [republic tape/session.py](/Users/dylan/DylanLi/repo/agent-group/infra-LLM /republic/src/republic/tape/session.py)
- [republic tape/context.py](/Users/dylan/DylanLi/repo/agent-group/infra-LLM /republic/src/republic/tape/context.py)

---

*文档生成时间: 2026-02-26*
