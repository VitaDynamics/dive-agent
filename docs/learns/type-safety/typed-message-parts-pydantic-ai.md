# 强类型 Message Parts 设计 (Pydantic AI)

> **Related topics**: [[streaming-tool-assembly-pydantic-ai]], [[async-streaming-first-class]]

## Overview

Pydantic AI 的强类型 Message Parts 设计展示了如何使用 Python 的类型系统来构建一个类型安全、可扩展的多模态消息系统。核心设计哲学是：**通过 Discriminator 模式和泛型，让编译器帮你保证消息处理的正确性**。

## Key Concepts

### 1. UserContent 联合类型 - 多模态输入的统一抽象

```python
# pydantic_ai/messages.py
UserContent = Union[
    str,                    # 纯文本
    ImageUrl,               # 图片 URL
    AudioUrl,               # 音频 URL
    VideoUrl,               # 视频 URL
    BinaryContent,          # 二进制内容
    DocumentUrl,            # 文档 URL
]
"""User content can be a string or any of the URL/content types."""
```

**设计亮点**：
- 最简单的 `str` 作为默认选项，向后兼容
- 多模态内容通过 URL 类型封装，延迟加载/验证
- 统一的 `FileUrl` 基类提供公共功能（force_download, vendor_metadata）

### 2. ModelMessage 层次结构 - 对话消息的类型安全表达

```python
# pydantic_ai/messages.py
ModelMessage = Annotated[
    Union[
        ModelRequest,       # 用户/系统的请求
        ModelResponse,      # 模型的响应
    ],
    Field(discriminator='kind'),  # Discriminator-based 序列化
]

@dataclass
class ModelRequest:
    """A request message sent to the model."""
    parts: list[ModelRequestPart]
    kind: Literal['request'] = 'request'

@dataclass
class ModelResponse:
    """A response message received from the model."""
    parts: list[ModelResponsePart]
    kind: Literal['response'] = 'response'
    timestamp: datetime = field(default_factory=now_utc)
```

**Discriminator 模式优势**：
- 序列化后自动反序列化到正确类型
- IDE 自动补全和类型检查
- 避免手动类型判断和转换

### 3. Part 类型系统 - 细粒度的内容组件

```python
# pydantic_ai/messages.py - 请求 Part
ModelRequestPart = Annotated[
    Union[
        SystemPromptPart,    # 系统提示
        UserPromptPart,      # 用户提示
        ToolReturnPart,      # 工具返回结果
        RetryPromptPart,     # 重试提示
    ],
    Field(discriminator='part_kind'),
]

# pydantic_ai/messages.py - 响应 Part
ModelResponsePart = Annotated[
    Union[
        TextPart,            # 文本内容
        ImagePart,           # 图片内容
        ToolCallPart,        # 工具调用
        ThinkingPart,        # 思考内容（如 Claude）
    ],
    Field(discriminator='part_kind'),
]
```

**每个 Part 都有 discriminator 字段**：
```python
@dataclass
class TextPart:
    content: str
    part_kind: Literal['text'] = 'text'  # Discriminator

@dataclass
class ToolCallPart:
    tool_name: str
    args: dict[str, Any]
    tool_call_id: str
    part_kind: Literal['tool-call'] = 'tool-call'  # Discriminator
```

### 4. ModelMessagesTypeAdapter - 类型安全的序列化

```python
# pydantic_ai/messages.py
ModelMessagesTypeAdapter = TypeAdapter(list[ModelMessage])
"""Type adapter for serializing/deserializing list[ModelMessage].

使用示例:
    # 序列化
    history = result.all_messages()
    json_bytes = ModelMessagesTypeAdapter.dump_json(history)

    # 反序列化
    same_history = ModelMessagesTypeAdapter.validate_json(json_bytes)
"""
```

**设计优势**：
- 一次配置，到处使用
- 自动处理 discriminator 的序列化/反序列化
- 支持多种格式（JSON, Python dict, bytes）

### 5. FileUrl 抽象基类 - 多模态内容的统一处理

```python
# pydantic_ai/messages.py
@pydantic_dataclass
class FileUrl(ABC):
    """Abstract base class for any URL-based file."""
    url: str
    force_download: ForceDownloadMode = False
    vendor_metadata: dict[str, Any] | None = None

    @computed_field
    @property
    def media_type(self) -> str:
        """Infer media type from URL or explicit value."""
        return self._media_type or self._infer_media_type()

    @computed_field
    @property
    def identifier(self) -> str:
        """Stable identifier for LLM to reference this file."""
        return self._identifier or _multi_modal_content_identifier(self.url)
```

**具体实现类**：
```python
@pydantic_dataclass
class ImageUrl(FileUrl):
    kind: Literal['image-url'] = 'image-url'

@pydantic_dataclass
class AudioUrl(FileUrl):
    kind: Literal['audio-url'] = 'audio-url'

@pydantic_dataclass
class VideoUrl(FileUrl):
    kind: Literal['video-url'] = 'video-url'
```

## Code Examples

### 示例 1: 构建多模态消息

```python
from pydantic_ai import Agent
from pydantic_ai.messages import ImageUrl, DocumentUrl

agent = Agent('openai:gpt-4o')

# 文本 + 图片 + 文档的多模态输入
result = await agent.run([
    "分析这张图片和这个文档",
    ImageUrl(url="https://example.com/chart.png"),
    DocumentUrl(url="https://example.com/report.pdf"),
])
```

### 示例 2: 类型安全的消息处理

```python
def process_message(message: ModelMessage) -> None:
    match message:
        case ModelRequest(parts=parts):
            for part in parts:
                match part:
                    case UserPromptPart(content=content):
                        print(f"用户: {content}")
                    case SystemPromptPart(content=content):
                        print(f"系统: {content}")
        case ModelResponse(parts=parts):
            for part in parts:
                match part:
                    case TextPart(content=text):
                        print(f"文本: {text}")
                    case ToolCallPart(tool_name=name, args=args):
                        print(f"工具调用: {name}({args})")
                    case ImagePart(data=data, mime_type=mime):
                        print(f"图片: {mime}, {len(data)} bytes")
```

### 示例 3: 消息历史的持久化与恢复

```python
from pydantic_ai.messages import ModelMessagesTypeAdapter

# 保存对话历史
history = result.all_messages()
as_json = ModelMessagesTypeAdapter.dump_json(history)
with open("conversation.json", "wb") as f:
    f.write(as_json)

# 恢复对话历史
with open("conversation.json", "rb") as f:
    restored = ModelMessagesTypeAdapter.validate_json(f.read())

# 继续对话
result2 = await agent.run("继续", message_history=restored)
```

## Design Decisions

### 为什么使用 Discriminator 模式？

**对比：传统 Union Type vs Discriminator**

```python
# 传统方式 - 需要手动类型检查
def process_part_bad(part: Union[TextPart, ToolCallPart]):
    if isinstance(part, TextPart):
        print(part.content)
    elif isinstance(part, ToolCallPart):
        print(part.tool_name)

# Discriminator 方式 - 编译器帮你检查
def process_part_good(part: ModelResponsePart):
    match part:
        case TextPart(content=c):  # 类型自动收窄
            print(c)
        case ToolCallPart(tool_name=n):
            print(n)
```

### 为什么区分 ModelRequestPart 和 ModelResponsePart？

1. **语义清晰**：明确区分"输入"和"输出"
2. **类型安全**：防止在错误的位置使用错误的 Part 类型
3. **扩展性**：可以独立扩展请求和响应的能力

### MediaType 作为 Literal Type 的优势

```python
ImageMediaType: TypeAlias = Literal[
    'image/jpeg', 'image/png', 'image/gif', 'image/webp'
]
```

- IDE 自动补全支持的图片格式
- 类型检查器可以在编译时发现错误
- 文档即代码，无需额外文档

## Related Files

- `/pydantic-ai/pydantic_ai_slim/pydantic_ai/messages.py` - Message 类型系统的核心定义
- `/pydantic-ai/pydantic_ai_slim/pydantic_ai/_parts_manager.py` - Part 的流式管理
- `/pydantic-ai/pydantic_ai_slim/pydantic_ai/result.py` - AgentStream 和输出处理

---

*Last updated: 2026-02-26*
