# 上下文擦除与转换能力对比

> **Related topics**: [[session-history-management]], [[republic-anchor-mechanism]]

## Overview

本文对比分析五个框架的 **上下文擦除/转换能力**，即如何在发送给 LLM 之前对历史消息进行过滤、精简或转换。

`★ Insight ─────────────────────────────────────`
**上下文擦除的基石是强类型的消息 Streaming**

只有当消息有明确的类型结构（如 `TapeEntry.kind`、`ModelMessage.part_kind`），才能实现精准的擦除逻辑：
- 擦除工具结果但保留工具调用
- 精简长代码块但保留签名
- 去重重复的文件读取记录
`─────────────────────────────────────────────────`

---

## 1. Republic: TapeContext.select 钩子

### 核心机制

```python
# tape/context.py
@dataclass(frozen=True)
class TapeContext:
    anchor: AnchorSelector = LAST_ANCHOR  # 从哪里切片
    select: Callable[[Sequence[TapeEntry], TapeContext], list[dict]] | None = None  # 如何转换
```

### 工作流程

```
Tape (不可变)
     ↓
_slice_after_anchor()  # 空间切片
     ↓
select(entries, context)  # 内容转换/擦除
     ↓
messages → LLM
```

### 场景 A: 擦除工具结果

```python
def prune_tool_results(entries: Sequence[TapeEntry], context: TapeContext):
    """擦除工具返回，只保留调用"""
    messages = []
    for entry in entries:
        if entry.kind == "message":
            messages.append(entry.payload)
        elif entry.kind == "tool_call":
            messages.append(entry.payload)
        # 故意跳过 tool_result
    return messages

# 使用
ctx = TapeContext(anchor=LAST_ANCHOR, select=prune_tool_results)
tape.chat("Check status again", context=ctx)
```

### 场景 B: 去重文件读取

```python
def deduplicate_file_reads(entries: Sequence[TapeEntry], context: TapeContext):
    """只保留最后一次文件读取"""
    last_file_reads: dict[str, TapeEntry] = {}
    result = []

    for entry in entries:
        if entry.kind == "tool_result":
            tool_name = entry.meta.get("tool_name")
            if tool_name == "read_file":
                file_path = entry.payload.get("path")
                last_file_reads[file_path] = entry  # 覆盖旧的
            else:
                result.append(entry.payload)
        else:
            result.append(entry.payload)

    # 添加最后一次读取
    for entry in last_file_reads.values():
        result.append(entry.payload)

    return result
```

### 设计哲学

| 原则 | 说明 |
|------|------|
| **Immutable Tape** | 原始磁带永远记录所有动作（审计证据） |
| **Dynamic View** | TapeContext 只是一个"滤镜"，让 LLM 看到干净版本 |
| **Separation of Concerns** | Anchor 负责"空间"，select 负责"内容" |

---

## 2. Kimi CLI: Compaction 协议

### 核心机制

```python
# soul/compaction.py
@runtime_checkable
class Compaction(Protocol):
    async def compact(self, messages: Sequence[Message], llm: LLM) -> Sequence[Message]:
        """将消息序列压缩为新的消息序列"""
        ...
```

### SimpleCompaction 实现

```python
class SimpleCompaction:
    def __init__(self, max_preserved_messages: int = 2):
        self.max_preserved_messages = max_preserved_messages

    async def compact(self, messages: Sequence[Message], llm: LLM) -> Sequence[Message]:
        compact_message, to_preserve = self.prepare(messages)
        if compact_message is None:
            return to_preserve

        # 使用 LLM 进行智能压缩
        result = await kosong.step(
            chat_provider=llm.chat_provider,
            system_prompt="You are a helpful assistant that compacts conversation context.",
            toolset=EmptyToolset(),
            history=[compact_message],
        )

        # 构建压缩后的消息
        content = [system("Previous context has been compacted. Here is the compaction output:")]
        content.extend(part for part in result.message.content if not isinstance(part, ThinkPart))
        compacted_messages = [Message(role="user", content=content)]
        compacted_messages.extend(to_preserve)
        return compacted_messages

    def prepare(self, messages: Sequence[Message]) -> PrepareResult:
        """准备压缩：保留最后 N 条消息，其余的待压缩"""
        # 从后往前找最后 N 条 user/assistant 消息
        # ...
```

### 压缩提示词 (compact.md)

```markdown
**Compression Priorities (in order):**
1. Current Task State: What is being worked on RIGHT NOW
2. Errors & Solutions: All encountered errors and their resolutions
3. Code Evolution: Final working versions only
4. System Context: Project structure, dependencies
5. Design Decisions: Architectural choices
6. TODO Items: Unfinished tasks

**Compression Rules:**
- MUST KEEP: Error messages, stack traces, working solutions
- MERGE: Similar discussions into single summary points
- REMOVE: Redundant explanations, failed attempts
- CONDENSE: Long code blocks → keep signatures + key logic
```

### 设计哲学

| 原则 | 说明 |
|------|------|
| **LLM-based Compression** | 使用 LLM 进行智能摘要，而非简单规则 |
| **Protocol-based** | Compaction 是 Protocol，可以自定义实现 |
| **Preserve Recent** | 保留最近 N 条消息，其余压缩 |

### 对比 Republic

| 特性 | Republic select | Kimi Compaction |
|------|-----------------|-----------------|
| **实现方式** | 纯 Python 函数 | LLM 智能压缩 |
| **擦除粒度** | Entry 级别 | Message 级别 |
| **保留原始** | ✅ Tape 不可变 | ❌ 压缩后替换 |
| **成本** | 无额外 API 调用 | 需要 LLM 调用 |

---

## 3. Pydantic AI: 手动管理 message_history

### 核心机制

```python
# agent/abstract.py
async def run(
    self,
    prompt: str,
    *,
    message_history: Sequence[ModelMessage] | None = None,  # 手动传入历史
    ...
) -> AgentRunResult[OutputDataT]:
    ...

# result.py
@dataclass
class AgentRunResult(Generic[OutputDataT]):
    def all_messages(self) -> list[ModelMessage]:
        """返回所有消息"""
        ...

    def new_messages(self) -> list[ModelMessage]:
        """返回本次新增的消息"""
        ...
```

### 手动擦除示例

```python
from pydantic_ai import Agent
from pydantic_ai.messages import ModelMessage, ToolReturnPart

agent = Agent('openai:gpt-4')

# 第一次对话
result1 = await agent.run("Read file A")
history = result1.all_messages()

# 手动擦除工具结果
def prune_tool_returns(messages: list[ModelMessage]) -> list[ModelMessage]:
    pruned = []
    for msg in messages:
        new_parts = []
        for part in msg.parts:
            if not isinstance(part, ToolReturnPart):
                new_parts.append(part)
        if new_parts:
            pruned.append(replace(msg, parts=new_parts))
    return pruned

pruned_history = prune_tool_returns(history)

# 继续对话
result2 = await agent.run("Read file B", message_history=pruned_history)
```

### 设计哲学

| 原则 | 说明 |
|------|------|
| **Explicit Control** | 用户完全控制历史，框架不做假设 |
| **Type-safe** | ModelMessage 是强类型，支持精准过滤 |
| **No Built-in Pruning** | 无内置擦除机制，需要手动实现 |

### 对比 Republic

| 特性 | Republic select | Pydantic AI |
|------|-----------------|-------------|
| **擦除入口** | TapeContext.select 钩子 | 手动处理 message_history |
| **类型支持** | entry.kind (str) | part_kind (Literal) |
| **自动化程度** | 半自动（声明式） | 完全手动 |

---

## 4. LitAI: 无擦除能力

### 核心机制

```python
# llm.py
class LLM:
    def chat(self, prompt, conversation=None, ...):
        # conversation 只是字符串 ID
        # 历史管理完全由 SDKLLM 内部处理
        ...

    def get_history(self, name: str) -> Optional[List[Dict[str, str]]]:
        """获取历史，但只是简单的 dict 列表"""
        return self._llm.get_history(name)
```

### 设计哲学

| 原则 | 说明 |
|------|------|
| **Simplicity First** | 极简 API，不暴露复杂的历史管理 |
| **SDK Handles It** | 历史管理交给 lightning_sdk |
| **No Pruning** | 无内置擦除能力 |

---

## 5. LangChain: Memory 抽象

### 核心机制

```python
# 多种 Memory 实现
from langchain.memory import (
    ConversationBufferMemory,        # 完整历史
    ConversationBufferWindowMemory,  # 滑动窗口
    ConversationSummaryMemory,       # LLM 摘要
    VectorStoreRetrieverMemory,      # 向量检索
)

# 滑动窗口示例
memory = ConversationBufferWindowMemory(k=5)  # 只保留最近 5 轮
memory.save_context({"input": "Hi"}, {"output": "Hello!"})
history = memory.load_memory_variables({})
```

### ConversationSummaryMemory

```python
from langchain.memory import ConversationSummaryMemory
from langchain_openai import OpenAI

llm = OpenAI()
memory = ConversationSummaryMemory(llm=llm)

# 自动使用 LLM 摘要旧对话
memory.save_context({"input": "Long conversation..."}, {"output": "Response..."})
# memory.buffer 会是摘要而非原始对话
```

### 设计哲学

| 原则 | 说明 |
|------|------|
| **Pluggable Memory** | 可插拔的 Memory 实现 |
| **Multiple Strategies** | 窗口、摘要、向量检索等多种策略 |
| **LLM-based Summary** | 支持 LLM 自动摘要 |

---

## 6. 对比总结

### 能力矩阵

| 框架 | 擦除能力 | 实现方式 | 类型基础 | 保留原始 |
|------|----------|----------|----------|----------|
| **Republic** | ✅ TapeContext.select | 纯函数钩子 | TapeEntry.kind | ✅ Tape 不可变 |
| **Kimi CLI** | ✅ Compaction | LLM 智能压缩 | Message + ContentPart | ❌ 压缩后替换 |
| **Pydantic AI** | ⚠️ 手动 | 处理 message_history | ModelMessage.part_kind | 取决于实现 |
| **LitAI** | ❌ 无 | - | dict | - |
| **LangChain** | ✅ Memory 抽象 | 窗口/摘要/向量 | 取决于实现 | 取决于实现 |

### 设计模式对比

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    上下文擦除模式对比                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│ Republic:     Tape (不可变) → select 钩子 → View (动态) → LLM               │
│ Kimi CLI:     Message[] → Compaction (LLM) → Compacted Message[] → LLM      │
│ Pydantic AI:  ModelMessage[] → 手动过滤 → message_history → LLM             │
│ LangChain:    Memory.load() → 窗口/摘要/向量 → messages → LLM               │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 强类型消息的基石作用

| 框架 | 消息类型 | 擦除精度 |
|------|----------|----------|
| **Republic** | `TapeEntry(kind="tool_result", payload={...})` | Entry 级别 |
| **Kimi CLI** | `Message(content=[TextPart, ThinkPart, ToolCall])` | Part 级别 |
| **Pydantic AI** | `ModelMessage(parts=[TextPart, ToolCallPart, ...])` | Part 级别 |
| **LitAI** | `{"role": "...", "content": "..."}` | 无结构，无法精准擦除 |

### 选择建议

| 场景 | 推荐方案 | 理由 |
|------|----------|------|
| **审计需求 + 精准擦除** | Republic select | Tape 不可变 + 类型化 Entry |
| **智能压缩 + 节省 Token** | Kimi Compaction | LLM 摘要保留关键信息 |
| **完全控制 + 强类型** | Pydantic AI 手动 | 类型安全 + 灵活 |
| **灵活的 Memory 策略** | LangChain Memory | 多种实现可切换 |
| **简单场景** | LitAI | 无需擦除 |

---

## 7. 关键洞察：强类型 Streaming 是基石

### 为什么强类型是必要条件？

```python
# ❌ 无类型：无法精准擦除
{"role": "assistant", "content": "I read the file. Here's the result: [1000 lines of code]..."}
# 只能整体保留或整体删除

# ✅ 有类型：精准擦除
Message(content=[
    TextPart(text="I read the file. Here's the result:"),
    ToolCallPart(tool_name="read_file", args={...}),
    ToolReturnPart(content="[1000 lines of code]..."),  # 可以只删除这个
])
```

### Republic 的 TapeEntry 类型系统

```python
@dataclass(frozen=True)
class TapeEntry:
    kind: str  # "message" | "tool_call" | "tool_result" | "error" | "anchor" | "event"
    payload: dict
    meta: dict  # run_id, provider, model, tool_name, ...
```

### Kimi CLI 的 ContentPart 类型系统

```python
@dataclass
class TextPart:
    text: str

@dataclass
class ThinkPart:
    think: str

@dataclass
class ToolCall:
    id: str
    function: FunctionBody

@dataclass
class ToolCallPart:
    arguments_part: str  # 流式增量
```

### Pydantic AI 的 Part 类型系统

```python
@dataclass
class TextPart:
    content: str
    part_kind: Literal['text'] = 'text'

@dataclass
class ToolCallPart:
    tool_name: str
    args: Any
    tool_call_id: str
    part_kind: Literal['tool-call'] = 'tool-call'

@dataclass
class ToolReturnPart:
    tool_name: str
    content: Any
    tool_call_id: str
    part_kind: Literal['tool-return'] = 'tool-return'
```

---

## 8. 结论

### Republic 的 TapeContext.select 是最优雅的设计

1. **不可变 Tape** - 保证审计证据完整
2. **动态 View** - LLM 看到干净的历史
3. **声明式 API** - 一行代码定义擦除逻辑
4. **类型化 Entry** - 支持精准擦除

### Kimi CLI 的 Compaction 是最智能的设计

1. **LLM 驱动** - 自动提取关键信息
2. **Protocol 抽象** - 可自定义压缩策略
3. **结构化输出** - 压缩结果有明确格式

### 其他框架需要手动实现

- **Pydantic AI** - 有类型基础，但需要手动实现过滤逻辑
- **LitAI** - 无类型基础，无法实现精准擦除
- **LangChain** - 有 Memory 抽象，但策略有限

---

*Last updated: 2026-02-25*
