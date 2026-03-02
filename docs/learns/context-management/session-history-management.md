# 会话与历史管理机制对比 - Tape vs 其他设计

> **Related topics**: [[llm-framework-comparison]], [[llm-abstraction-comparison]]

## Overview

本文对比分析五个框架的会话与历史管理机制，重点分析 **Republic 的 Tape** 设计与其他框架的差异。

---

## 1. Republic: Tape (磁带) 设计

### 核心概念

**Tape** 名字来源于 "磁带" (Magnetic Tape)，象征着：
- **只追加** (Append-only) - 不能修改历史，只能添加新记录
- **顺序记录** - 按时间顺序记录所有交互
- **可回放** - 可以从头读取完整的对话历史

### 数据结构

```python
# tape/entries.py
@dataclass(frozen=True)
class TapeEntry:
    """Tape 中的单个条目 - 不可变"""
    id: int
    kind: str          # 条目类型
    payload: dict      # 具体内容
    meta: dict         # 元数据 (run_id, provider, model 等)
```

### Entry 类型

| kind | 含义 | payload |
|------|------|---------|
| `message` | 用户/助手消息 | `{"role": "...", "content": "..."}` |
| `system` | 系统提示 | `{"content": "..."}` |
| `tool_call` | 工具调用 | `{"calls": [...]}` |
| `tool_result` | 工具结果 | `{"results": [...]}` |
| `error` | 错误记录 | `ErrorPayload.as_dict()` |
| `anchor` | **锚点** | `{"name": "...", "state": {...}}` |
| `event` | 事件记录 | `{"name": "run", "data": {...}}` |

### Anchor (锚点) - 上下文窗口管理

```python
# tape/context.py
@dataclass(frozen=True)
class TapeContext:
    """控制如何从 Tape 中选择消息"""
    anchor: AnchorSelector = LAST_ANCHOR  # 从哪个锚点开始
    select: Callable | None = None        # 自定义选择器

# Anchor 选择器:
# - LAST_ANCHOR: 从最近的锚点开始 (默认)
# - None: 使用完整的 Tape
# - "anchor_name": 从指定名称的锚点开始
```

### 工作流程

```
┌─────────────────────────────────────────────────────────────────┐
│                         Tape (磁带)                              │
├─────────────────────────────────────────────────────────────────┤
│  [0] system: "You are a helpful assistant"                      │
│  [1] message: {"role": "user", "content": "Hello"}              │
│  [2] message: {"role": "assistant", "content": "Hi!"}           │
│  [3] anchor: {"name": "greeting_done", "state": {...}} ← 锚点1  │
│  [4] message: {"role": "user", "content": "What's weather?"}    │
│  [5] tool_call: {"calls": [{"name": "get_weather", ...}]}       │
│  [6] tool_result: {"results": ["sunny"]}                        │
│  [7] message: {"role": "assistant", "content": "It's sunny"}    │
│  [8] anchor: {"name": "weather_done", "state": {...}} ← 锚点2   │
└─────────────────────────────────────────────────────────────────┘
         ↑
         │ TapeContext(anchor=LAST_ANCHOR)
         │ 只读取锚点2之后的消息发送给 LLM
         ↓
┌─────────────────────────────────────────────────────────────────┐
│  发送给 LLM 的消息:                                              │
│  [4] message: {"role": "user", "content": "What's weather?"}    │
│  [5] tool_call / tool_result                                    │
│  [7] message: {"role": "assistant", "content": "It's sunny"}    │
│  + 新的用户消息                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 使用示例

```python
from republic import LLM
from republic.tape import TapeContext

llm = LLM(model="openai:gpt-4")

# 创建 Tape (命名会话)
tape = llm.tape("conversation-1")

# 第一次对话
tape.chat("Hello!")

# 创建锚点 - 标记检查点
tape.handoff("intro_done", state={"user_name": "Alice"})

# 第二次对话 - 默认只发送锚点之后的消息
tape.chat("What's the weather?")

# 读取完整历史
all_entries = tape.read_entries()

# 只读取锚点之后的消息 (用于发送给 LLM)
messages = tape.read_messages()

# 自定义上下文选择
context = TapeContext(anchor=None)  # 使用完整历史
all_messages = tape.read_messages(context=context)

# 查询特定条目
tool_calls = tape.query().tool_calls().all()
errors = tape.query().errors().all()
```

### Tape 的设计优势

1. **完整的可观测性** - 所有交互都有记录
2. **上下文窗口管理** - Anchor 控制发送给 LLM 的历史长度
3. **调试友好** - 可以查询任意类型的条目
4. **状态恢复** - 可以从任意 Anchor 恢复对话
5. **审计追踪** - 不可变记录，适合生产环境

---

## 2. LitAI: Conversation 字符串

### 设计理念

**最简单的会话管理** - 仅使用字符串 ID 标识会话。

### 实现

```python
# litai/llm.py
class LLM:
    def chat(
        self,
        prompt: str,
        conversation: Optional[str] = None,  # 会话 ID
        ...
    ) -> str:
        response = model.chat(
            prompt=prompt,
            conversation=conversation,  # 传递给 SDKLLM
            ...
        )
        return response

    def reset_conversation(self, name: str) -> None:
        """重置会话历史"""
        self._llm.reset_conversation(name)

    def get_history(self, name: str) -> Optional[List[Dict[str, str]]]:
        """获取会话历史"""
        return self._llm.get_history(name)

    def list_conversations(self) -> List[str]:
        """列出所有会话"""
        return self._llm.list_conversations()
```

### 使用示例

```python
llm = LLM(model="openai/gpt-4")

# 无状态调用
llm.chat("What is AI?")

# 有状态调用
llm.chat("What is Lightning AI?", conversation="research")
llm.chat("Tell me more", conversation="research")  # 保持上下文

# 查看历史
llm.get_history("research")

# 重置
llm.reset_conversation("research")
```

### 特点

| 优点 | 缺点 |
|------|------|
| 极简 API | 无结构化记录 |
| 易于理解 | 无上下文窗口管理 |
| SDK 内部管理 | 无查询能力 |

**对比 Tape**: LitAI 的 `conversation` 只是简单的字符串 ID，历史管理完全由 `SDKLLM` 内部处理，用户无法访问结构化数据。

---

## 3. Pydantic AI: ModelMessage 类型系统

### 设计理念

**强类型消息系统** - 每种消息都有对应的类型，支持完整的类型检查。

### 消息类型

```python
# messages.py
@dataclass(repr=False)
class SystemPromptPart:
    """系统提示"""
    content: str
    timestamp: datetime
    dynamic_ref: str | None
    part_kind: Literal['system-prompt'] = 'system-prompt'

@dataclass(repr=False)
class UserPromptPart:
    """用户输入"""
    content: str | Sequence[Any]
    timestamp: datetime
    part_kind: Literal['user-prompt'] = 'user-prompt'

@dataclass(repr=False)
class TextPart:
    """文本内容"""
    content: str
    part_kind: Literal['text'] = 'text'

@dataclass(repr=False)
class ToolCallPart:
    """工具调用"""
    tool_name: str
    args: Any
    tool_call_id: str
    part_kind: Literal['tool-call'] = 'tool-call'

@dataclass(repr=False)
class ToolReturnPart:
    """工具返回"""
    tool_name: str
    content: Any
    tool_call_id: str
    timestamp: datetime
    part_kind: Literal['tool-return'] = 'tool-return'

@dataclass(repr=False)
class RetryPromptPart:
    """重试提示"""
    content: Any
    tool_call_id: str
    timestamp: datetime
    part_kind: Literal['retry-prompt'] = 'retry-prompt'

@dataclass
class ModelMessage:
    """完整消息 - 包含多个 Part"""
    parts: list[ModelMessagePart]
    timestamp: datetime
    kind: Literal['message'] = 'message'

@dataclass
class ModelResponse:
    """模型响应"""
    parts: list[ModelResponsePart]
    timestamp: datetime
    usage: RequestUsage | None
    model_name: str | None
    kind: Literal['response'] = 'response'
```

### 历史管理

```python
# 使用 Agent 管理历史
result = await agent.run("Hello")
history = result.all_messages()  # 返回 list[ModelMessage]

# 继续对话
result2 = await agent.run("Continue", message_history=history)
```

### 使用示例

```python
from pydantic_ai import Agent

agent = Agent('openai:gpt-4')

# 第一次对话
result1 = await agent.run("What is AI?")
print(result1.output)

# 获取历史
history = result1.all_messages()

# 继续对话 - 传入历史
result2 = await agent.run("Tell me more", message_history=history)
```

### 特点

| 优点 | 缺点 |
|------|------|
| 强类型，IDE 友好 | 无内置持久化 |
| 完整的消息类型 | 无上下文窗口管理 |
| 支持 OpenTelemetry | 需要手动管理历史 |

**对比 Tape**: Pydantic AI 有完整的类型系统，但没有 Tape 的 Anchor 锚点机制，也没有内置的上下文窗口管理。

---

## 4. Kimi CLI: Session + Wire File

### 设计理念

**生产级会话管理** - 持久化到磁盘，支持多会话、状态恢复。

### 数据结构

```python
# session.py
@dataclass(slots=True, kw_only=True)
class Session:
    """会话"""
    id: str                              # 会话 ID
    work_dir: KaosPath                   # 工作目录
    work_dir_meta: WorkDirMeta           # 元数据
    context_file: Path                   # 消息历史文件 (context.jsonl)
    wire_file: WireFile                  # 线消息日志 (wire.jsonl)
    state: SessionState                  # 持久化状态
    title: str                           # 会话标题
    updated_at: float                    # 更新时间

# session_state.py
class SessionState(BaseModel):
    """持久化状态"""
    version: int = 1
    approval: ApprovalStateData          # 审批状态
    dynamic_subagents: list[DynamicSubagentSpec]  # 动态子 agent

class ApprovalStateData(BaseModel):
    yolo: bool = False                   # 跳过所有确认
    auto_approve_actions: set[str]       # 自动批准的操作
```

### 文件结构

```
~/.kimi-cli/
└── sessions/
    └── <work_dir_hash>/
        └── <session_id>/
            ├── context.jsonl    # 消息历史 (kosong Message)
            ├── wire.jsonl       # 线消息日志 (完整记录)
            └── state.json       # 会话状态
```

### 使用示例

```python
from kimi_cli.session import Session

# 创建新会话
session = await Session.create(work_dir="/path/to/project")

# 查找现有会话
session = await Session.find(work_dir, session_id="xxx")

# 继续最近的会话
session = await Session.continue_(work_dir)

# 列出所有会话
sessions = await Session.list(work_dir)

# 保存状态
session.state.approval.yolo = True
session.save_state()

# 删除会话
await session.delete()
```

### Wire File - 完整记录

```python
# wire/types.py
@dataclass
class TurnBegin:
    """对话开始"""
    user_input: str
    timestamp: float

@dataclass
class TurnEnd:
    """对话结束"""
    status: str
    usage: TokenUsage | None

@dataclass
class MessagePart:
    """消息部分"""
    kind: str  # "text", "tool_call", "tool_result", "think"
    data: Any
```

### 特点

| 优点 | 缺点 |
|------|------|
| 持久化到磁盘 | 复杂度高 |
| 多会话管理 | 无 Anchor 锚点 |
| 完整的线消息日志 | 与 CLI 紧密耦合 |
| 状态恢复 | |

**对比 Tape**: Kimi CLI 的 `wire.jsonl` 类似 Tape，记录完整交互，但没有 Anchor 锚点机制。`context.jsonl` 存储当前消息历史。

---

## 5. LangChain: Memory 抽象

### 设计理念

**可插拔的 Memory 系统** - 多种内存实现，支持自定义。

### Memory 类型

```python
# 内置 Memory 类型
from langchain.memory import (
    ConversationBufferMemory,        # 完整历史
    ConversationBufferWindowMemory,  # 滑动窗口
    ConversationSummaryMemory,       # 摘要
    ConversationKGMemory,            # 知识图谱
    VectorStoreRetrieverMemory,      # 向量检索
)

# 使用示例
memory = ConversationBufferMemory(return_messages=True)
memory.save_context({"input": "Hi"}, {"output": "Hello!"})
history = memory.load_memory_variables({})
```

### RunnableWithMessageHistory

```python
from langchain_core.runnables.history import RunnableWithMessageHistory
from langchain_community.chat_message_histories import FileChatMessageHistory

def get_session_history(session_id: str):
    return FileChatMessageHistory(f"chat_history/{session_id}.json")

chain_with_history = RunnableWithMessageHistory(
    chain,
    get_session_history,
    input_messages_key="input",
    history_messages_key="chat_history",
)

# 使用
chain_with_history.invoke(
    {"input": "Hello"},
    config={"configurable": {"session_id": "user-123"}},
)
```

### 特点

| 优点 | 缺点 |
|------|------|
| 多种 Memory 实现 | 概念复杂 |
| 可插拔设计 | 版本变化大 |
| 支持向量检索 | 性能开销 |
| 社区生态丰富 | |

**对比 Tape**: LangChain 的 Memory 系统更灵活，但没有 Tape 的结构化 Entry 和 Anchor 锚点机制。

---

## 6. 对比总结

### 核心差异

| 特性 | Republic Tape | LitAI Conversation | Pydantic AI ModelMessage | Kimi CLI Session | LangChain Memory |
|------|---------------|--------------------|--------------------------|------------------|------------------|
| **数据结构** | TapeEntry[] | dict (内部) | ModelMessage[] | context.jsonl | 多种实现 |
| **只追加** | ✅ | ❌ | ❌ | ✅ (wire.jsonl) | 取决于实现 |
| **锚点机制** | ✅ Anchor | ❌ | ❌ | ❌ | ❌ |
| **持久化** | ✅ TapeStore | SDK 内部 | ❌ | ✅ 文件系统 | 可选 |
| **类型系统** | dict (灵活) | dict | 强类型 dataclass | kosong Message | 多种 |
| **查询能力** | ✅ TapeQuery | ❌ | ❌ | wire.jsonl | 取决于实现 |
| **上下文管理** | ✅ TapeContext | ❌ | ❌ | ❌ | ✅ Window/Summary |

### Anchor 锚点 - Republic 独有

```
Republic 的 Anchor 是独特的上下文窗口管理机制:

1. 标记检查点 - handoff("task_done", state={...})
2. 状态传递 - 携带状态到下一个任务
3. 上下文重置 - 新任务从锚点开始，不携带之前的历史
4. 窗口控制 - 只发送锚点之后的消息给 LLM，节省 token
```

### 设计选择建议

| 场景 | 推荐框架 | 理由 |
|------|----------|------|
| 需要完整的可观测性和审计 | **Republic** | Tape + Anchor |
| 简单的对话历史 | **LitAI** | conversation 字符串 |
| 强类型需求 | **Pydantic AI** | ModelMessage 类型系统 |
| 生产级 CLI 应用 | **Kimi CLI** | Session + 持久化 |
| 灵活的 Memory 需求 | **LangChain** | 可插拔 Memory |

---

## 7. Tape 设计的启发

### 为什么 Tape 设计独特？

1. **结构化记录** - 每个交互都有明确的类型和元数据
2. **不可变性** - Entry 是 frozen dataclass，不能修改
3. **Anchor 锚点** - 解决上下文窗口管理问题
4. **查询能力** - TapeQuery 支持按类型查询

### 如果要在其他框架中实现类似功能

**Pydantic AI 扩展**:
```python
@dataclass
class TapeLikeHistory:
    entries: list[ModelMessage | ModelResponse]
    anchors: dict[str, int]  # anchor_name -> index

    def slice_from_anchor(self, anchor: str) -> list[ModelMessage]:
        start = self.anchors.get(anchor, 0)
        return [e for e in self.entries[start:] if isinstance(e, ModelMessage)]
```

**LitAI 扩展**:
```python
class LLM:
    def get_tape(self, conversation: str) -> list[dict]:
        """返回结构化的 Tape 记录"""
        history = self.get_history(conversation, raw=True)
        return [{"kind": "message", "payload": msg} for msg in history]
```

---

*Last updated: 2026-02-25*
