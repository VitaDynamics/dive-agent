# 工具调用流式组装设计

> **Related topics**: [[streaming-comparison]], [[llm-abstraction-comparison]], [[typed-message-parts-pydantic-ai]]

## Overview

工具调用流式组装是 LLM 抽象层中的核心问题：当模型以流式方式返回工具调用时，响应可能被分割成多个片段（delta），框架需要能够将这些片段正确地组装成完整的工具调用。本文分析 pydantic-ai 和 kimi-cli (kosong) 两个框架的实现方案。

## 核心问题

### 1. 流式响应的挑战

LLM 的流式响应中，工具调用可能以以下方式到达：

```
片段1: {"tool_name": "search", "arguments": "{\"query\":"}
片段2: "\"hello world\"}"
```

或者：

```
片段1: {"tool_name": "search"}
片段2: {"arguments": {"query": "hello world"}}
```

框架需要处理：
- **增量组装**：将多个片段合并为完整的工具调用
- **类型一致性**：处理字符串 JSON 和字典类型的参数
- **完整性检测**：判断工具调用是否已接收完毕
- **多工具并发**：同时处理多个工具调用的流式响应

## pydantic-ai 的实现

### 核心类型定义

**文件**: `pydantic-ai/pydantic_ai_slim/pydantic_ai/messages.py`

```python
@dataclass(repr=False)
class BaseToolCallPart:
    """A tool call from a model."""
    tool_name: str
    args: str | dict[str, Any] | None = None
    tool_call_id: str = field(default_factory=_generate_tool_call_id)
    # ... provider metadata ...

@dataclass(repr=False)
class ToolCallPart(BaseToolCallPart):
    """A tool call from a model."""
    part_kind: Literal['tool-call'] = 'tool-call'

@dataclass(repr=False, kw_only=True)
class ToolCallPartDelta:
    """A partial update (delta) for a `ToolCallPart`."""
    tool_name_delta: str | None = None
    args_delta: str | dict[str, Any] | None = None
    tool_call_id: str | None = None
    part_delta_kind: Literal['tool_call'] = 'tool_call'
```

### Delta 应用机制

**文件**: `pydantic-ai/pydantic_ai_slim/pydantic_ai/messages.py:1850-1950`

```python
def apply(self, part: ModelResponsePart | ToolCallPartDelta) -> ToolCallPart | BuiltinToolCallPart | ToolCallPartDelta:
    """Apply this delta to a part or delta, returning a new part or delta with the changes applied."""
    if isinstance(part, ToolCallPart | BuiltinToolCallPart):
        return self._apply_to_part(part)
    if isinstance(part, ToolCallPartDelta):
        return self._apply_to_delta(part)
    raise ValueError(...)

def _apply_to_part(self, part: ToolCallPart | BuiltinToolCallPart) -> ToolCallPart | BuiltinToolCallPart:
    """Apply delta directly to a ToolCallPart."""
    if self.tool_name_delta:
        tool_name = part.tool_name + self.tool_name_delta
        part = replace(part, tool_name=tool_name)

    if isinstance(self.args_delta, str):
        # 字符串参数：追加
        updated_json = (part.args or '') + self.args_delta
        part = replace(part, args=updated_json)
    elif isinstance(self.args_delta, dict):
        # 字典参数：合并
        updated_dict = {**(part.args or {}), **self.args_delta}
        part = replace(part, args=updated_dict)

    return part
```

### PartsManager：流式组装管理器

**文件**: `pydantic-ai/pydantic_ai_slim/pydantic_ai/_parts_manager.py`

`ModelResponsePartsManager` 是 pydantic-ai 流式组装的核心：

```python
@dataclass
class ModelResponsePartsManager:
    """Manages a sequence of parts that make up a model's streamed response."""
    _parts: list[ManagedPart] = field(default_factory=list[ManagedPart], init=False)
    _vendor_id_to_part_index: dict[VendorId, int] = field(default_factory=dict[VendorId, int], init=False)
```

#### 关键方法

**处理工具调用 Delta**：

```python
def handle_tool_call_delta(
    self,
    *,
    vendor_part_id: Hashable | None,
    tool_name: str | None = None,
    args: str | dict[str, Any] | None = None,
    tool_call_id: str | None = None,
    provider_name: str | None = None,
    provider_details: dict[str, Any] | None = None,
) -> ModelResponseStreamEvent | None:
    """Handle or update a tool call.

    Managed items remain as `ToolCallPartDelta`s until they have
    at least a tool_name, at which point they are upgraded to `ToolCallPart`s.
    """
    # 1. 查找现有部分
    existing = self._find_existing_part(vendor_part_id)

    if existing is None:
        # 2. 创建新的 Delta
        delta = ToolCallPartDelta(...)
        part = delta.as_part() or delta  # 如果完整则转为 Part
        new_index = self._append_part(part, vendor_part_id)

        # 只有完整时才发出 PartStartEvent
        if isinstance(part, ToolCallPart | BuiltinToolCallPart):
            return PartStartEvent(index=new_index, part=part)
    else:
        # 3. 更新现有部分
        updated_part = delta.apply(existing)
        self._parts[part_index] = updated_part

        if isinstance(updated_part, ToolCallPart | BuiltinToolCallPart):
            if isinstance(existing, ToolCallPartDelta):
                # Delta 升级为完整 Part
                return PartStartEvent(index=part_index, part=updated_part)
            else:
                # 已有 Part 的更新
                return PartDeltaEvent(index=part_index, delta=delta)
```

### 完整性检测策略

pydantic-ai 使用 **tool_name 存在性**作为完整性判断标准：

```python
def as_part(self) -> ToolCallPart | None:
    """Convert this delta to a fully formed `ToolCallPart` if possible."""
    if self.tool_name_delta is None:
        return None
    return ToolCallPart(
        self.tool_name_delta,
        self.args_delta,
        self.tool_call_id or _generate_tool_call_id(),
        ...
    )
```

**关键设计**：
- 只要有 `tool_name` 就认为工具调用已完整
- 参数可以是部分的（JSON 字符串片段或部分字典）
- 通过 `PartDeltaEvent` 继续更新参数

### 类型安全处理

pydantic-ai 严格区分字符串和字典类型的参数：

```python
def _apply_to_delta(self, delta: ToolCallPartDelta) -> ToolCallPart | BuiltinToolCallPart | ToolCallPartDelta:
    if isinstance(self.args_delta, str):
        if isinstance(delta.args_delta, dict):
            raise UnexpectedModelBehavior(
                'Cannot apply JSON deltas to non-JSON tool arguments'
            )
        updated_args_delta = (delta.args_delta or '') + self.args_delta
        # ...
    elif isinstance(self.args_delta, dict):
        if isinstance(delta.args_delta, str):
            raise UnexpectedModelBehavior(
                'Cannot apply dict deltas to non-dict tool arguments'
            )
        updated_args_delta = {**(delta.args_delta or {}), **self.args_delta}
        # ...
```

## kimi-cli (kosong) 的实现

### 核心类型定义

**文件**: `kimi-cli/packages/kosong/src/kosong/message.py`

```python
class ToolCall(BaseModel, MergeableMixin):
    """A tool call requested by the assistant."""

    class FunctionBody(BaseModel):
        name: str
        arguments: str | None  # JSON string format

    type: Literal["function"] = "function"
    id: str
    function: FunctionBody
    extras: dict[str, JsonType] | None = None

class ToolCallPart(BaseModel, MergeableMixin):
    """A part of the tool call - used for streaming."""
    arguments_part: str | None = None
    """A part of the arguments of the tool call."""
```

### MergeableMixin：合并协议

**文件**: `kimi-cli/packages/kosong/src/kosong/message.py:16-19`

```python
class MergeableMixin:
    def merge_in_place(self, other: Any) -> bool:
        """Merge the other part into the current part.
        Return True if the merge is successful."""
        return False
```

### ToolCall 的合并实现

```python
class ToolCall(BaseModel, MergeableMixin):
    # ...
    @override
    def merge_in_place(self, other: Any) -> bool:
        if not isinstance(other, ToolCallPart):
            return False
        if self.function.arguments is None:
            self.function.arguments = other.arguments_part
        else:
            self.function.arguments += other.arguments_part or ""
        return True

class ToolCallPart(BaseModel, MergeableMixin):
    # ...
    @override
    def merge_in_place(self, other: Any) -> bool:
        if not isinstance(other, ToolCallPart):
            return False
        if self.arguments_part is None:
            self.arguments_part = other.arguments_part
        else:
            self.arguments_part += other.arguments_part or ""
        return True
```

### 流式组装逻辑

**文件**: `kimi-cli/packages/kosong/src/kosong/_generate.py`

```python
async def generate(
    chat_provider: ChatProvider,
    system_prompt: str,
    tools: Sequence[Tool],
    history: Sequence[Message],
    *,
    on_message_part: Callback[[StreamedMessagePart], None] | None = None,
    on_tool_call: Callback[[ToolCall], None] | None = None,
) -> "GenerateResult":
    message = Message(role="assistant", content=[])
    pending_part: StreamedMessagePart | None = None

    stream = await chat_provider.generate(system_prompt, tools, history)
    async for part in stream:
        if pending_part is None:
            pending_part = part
        elif not pending_part.merge_in_place(part):  # 尝试合并
            # 无法合并，推送 pending_part
            _message_append(message, pending_part)
            if isinstance(pending_part, ToolCall) and on_tool_call:
                await callback(on_tool_call, pending_part)
            pending_part = part

    # 处理最后 pending 的部分
    if pending_part is not None:
        _message_append(message, pending_part)
```

### StreamedMessagePart 类型联合

**文件**: `kimi-cli/packages/kosong/src/kosong/chat_provider/__init__.py`

```python
type StreamedMessagePart = ContentPart | ToolCall | ToolCallPart
```

kosong 使用**类型区分**来识别流式片段：
- `ToolCall`：完整的工具调用（有 id、function name、arguments）
- `ToolCallPart`：仅包含 arguments_part 的片段

## 设计对比

| 特性 | pydantic-ai | kimi-cli (kosong) |
|------|-------------|-------------------|
| **Delta 类型** | `ToolCallPartDelta` 显式 delta 类 | `ToolCallPart` 轻量级片段 |
| **合并机制** | `apply()` 方法返回新对象 | `merge_in_place()` 原地修改 |
| **完整性判断** | `tool_name` 存在即完整 | 类型区分（ToolCall vs ToolCallPart）|
| **参数类型** | 支持字符串和字典 | 仅字符串 JSON |
| **管理器** | `ModelResponsePartsManager` | 简单的 `pending_part` 指针 |
| **事件系统** | `PartStartEvent` / `PartDeltaEvent` | 回调函数 `on_tool_call` |

## 对 Rust LLM 抽象层的启示

### 1. 类型设计

```rust
// 借鉴 pydantic-ai 的分离设计
pub struct ToolCall {
    pub tool_name: String,
    pub args: ToolArgs,  // 枚举：JsonString 或 Object
    pub tool_call_id: String,
}

pub struct ToolCallDelta {
    pub tool_name_delta: Option<String>,
    pub args_delta: Option<ToolArgs>,
    pub tool_call_id: Option<String>,
}

pub enum ToolArgs {
    JsonString(String),
    Object(Map<String, Value>),
}
```

### 2. 合并 trait

```rust
pub trait Mergeable {
    /// 尝试将 delta 合并到 self
    fn merge(&mut self, delta: ToolCallDelta) -> Result<(), MergeError>;

    /// 检查是否已完整（可以执行）
    fn is_complete(&self) -> bool;
}

impl Mergeable for ToolCall {
    fn merge(&mut self, delta: ToolCallDelta) -> Result<(), MergeError> {
        // 类型检查：字符串只能追加到字符串，字典只能合并到字典
        match (&mut self.args, delta.args_delta) {
            (ToolArgs::JsonString(s), Some(ToolArgs::JsonString(d))) => {
                s.push_str(&d);
            }
            (ToolArgs::Object(m), Some(ToolArgs::Object(d))) => {
                m.extend(d);
            }
            _ => return Err(MergeError::TypeMismatch),
        }
        Ok(())
    }

    fn is_complete(&self) -> bool {
        // 有 tool_name 即认为完整
        !self.tool_name.is_empty()
    }
}
```

### 3. 流式组装器

```rust
pub struct ToolCallAssembler {
    /// 按 vendor_part_id 索引的部分
    parts: HashMap<VendorId, ToolCall>,
    /// 待完成的 delta（还没有 tool_name）
    pending_deltas: HashMap<VendorId, ToolCallDelta>,
    /// 按顺序排列的完整工具调用
    completed: Vec<ToolCall>,
}

impl ToolCallAssembler {
    pub fn handle_delta(
        &mut self,
        vendor_part_id: Option<VendorId>,
        delta: ToolCallDelta,
    ) -> Result<AssemblyEvent, AssemblyError> {
        match vendor_part_id {
            Some(id) => {
                // 查找或创建
                if let Some(part) = self.parts.get_mut(&id) {
                    part.merge(delta)?;
                    Ok(AssemblyEvent::Updated { id })
                } else {
                    // 新部分
                    if delta.tool_name_delta.is_some() {
                        let part = ToolCall::from_delta(delta)?;
                        self.parts.insert(id, part);
                        Ok(AssemblyEvent::Started { id })
                    } else {
                        self.pending_deltas.insert(id, delta);
                        Ok(AssemblyEvent::Pending { id })
                    }
                }
            }
            None => {
                // 无 ID：追加到最新部分或创建新部分
                // ...
            }
        }
    }
}
```

### 4. 关键设计决策

**决策 1：完整性判断标准**
- 选项 A：有 `tool_name` 即完整（pydantic-ai）
- 选项 B：有完整参数才完整
- **建议**：选项 A，因为 LLM 可能先发送 tool_name 再流式发送参数

**决策 2：参数类型处理**
- 选项 A：仅支持字符串 JSON（简单）
- 选项 B：支持字符串和字典（灵活，需类型检查）
- **建议**：选项 B，但用类型系统保证安全

**决策 3：并发多工具**
- 选项 A：按 vendor_part_id 索引（pydantic-ai）
- 选项 B：顺序处理（kosong）
- **建议**：选项 A，支持交错传输的工具调用流

## 代码示例

### pydantic-ai 使用示例

```python
from pydantic_ai import Agent
from pydantic_ai.messages import ToolCallPart

agent = Agent('openai:gpt-4', tools=[search_tool])

async with agent.run_stream('Search for Python tutorials') as stream:
    async for event in stream:
        if isinstance(event, PartStartEvent):
            if isinstance(event.part, ToolCallPart):
                print(f"Tool started: {event.part.tool_name}")
        elif isinstance(event, PartDeltaEvent):
            if isinstance(event.delta, ToolCallPartDelta):
                print(f"Args updated: {event.delta.args_delta}")
```

### kosong 使用示例

```python
from kosong import generate
from kosong.message import ToolCall

result = await generate(
    provider,
    system_prompt="You are a helpful assistant",
    tools=[search_tool],
    history=messages,
    on_tool_call=lambda tc: print(f"Tool call: {tc.function.name}")
)

for tc in result.message.tool_calls:
    print(f"Complete: {tc.function.name}({tc.function.arguments})")
```

## 相关文件

### pydantic-ai
- `pydantic-ai/pydantic_ai_slim/pydantic_ai/messages.py:1200-1950` - ToolCallPart 和 ToolCallPartDelta 定义
- `pydantic-ai/pydantic_ai_slim/pydantic_ai/_parts_manager.py` - ModelResponsePartsManager 实现
- `pydantic-ai/tests/test_parts_manager.py` - 流式组装测试

### kimi-cli (kosong)
- `kimi-cli/packages/kosong/src/kosong/message.py` - ToolCall 和 ToolCallPart 定义
- `kimi-cli/packages/kosong/src/kosong/_generate.py` - generate 函数和 merge_in_place 逻辑
- `kimi-cli/packages/kosong/src/kosong/chat_provider/__init__.py` - StreamedMessagePart 类型定义

---
*Last updated: 2026-02-26*
