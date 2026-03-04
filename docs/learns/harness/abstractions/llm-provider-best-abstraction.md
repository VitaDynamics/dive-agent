---
tags: abstraction, architecture, harness, pydantic-ai, kosong, agentscope, comparison, rust, llm-client
---

# LLM Provider 最佳抽象模式研究

> **范围**：深入分析 pydantic-ai, kosong (kimi-cli), agentscope, llm-client (Rust) 等框架如何实现对不同 LLM Provider 的统一抽象，探讨接口设计、消息模型、流式处理及能力管理的最佳实践。
>
> **综合自**：pydantic-ai, kosong, agentscope, pi-mono, rust-llm-client-design
>
> **优先级**：P1

---

## 概述

随着 LLM 生态的碎片化，如何构建一个既能抹平各 Provider 差异，又能保留各自特性的抽象层，成为 Agent 框架设计的核心挑战。一个好的抽象层应该能够处理：
1. **消息协议转换**：统一 User/Assistant/System/Tool 消息格式。
2. **流式响应处理**：将各异的流式 Delta 转换为统一的消息流。
3. **能力与限制管理**：识别模型是否支持工具调用、图片输入、长上下文等。
4. **供应商特有逻辑**：处理如 Mistral 的工具 ID 长度要求或 Anthropic 的缓存标记。
5. **API 所有权边界**：明确哪些是内部实现细节，哪些是公共接口。
6. **错误可恢复性**：将重试逻辑内聚到错误类型本身，而非外部分类器。

---

## 核心模式与实现

### 1. 结构化协议 vs 抽象基类 (Protocol vs ABC)

在定义 Provider 接口时，现代框架呈现出两种主要路径。

#### 框架：kosong (Protocol-based)
使用 Python 的 `Protocol` 进行结构化类型定义，强调“鸭子类型”，不强制继承。

```python
@runtime_checkable
class ChatProvider(Protocol):
    name: str
    async def generate(
        self,
        system_prompt: str,
        tools: Sequence[Tool],
        history: Sequence[Message],
    ) -> "StreamedMessage": ...
```

**设计理由**：
- **解耦**：Provider 实现无需导入框架基类。
- **灵活性**：更容易通过组合或装饰器扩展功能。

#### 框架：pydantic-ai (ABC-based)
使用 `abc.ABC` 定义严格的继承体系，并提供大量内置钩子。

```python
class Model(ABC):
    @abstractmethod
    async def request(
        self,
        messages: list[ModelMessage],
        model_settings: ModelSettings | None,
        model_request_parameters: ModelRequestParameters,
    ) -> ModelResponse: ...
```

**设计理由**：
- **一致性**：强制实现所有必需方法。
- **复用**：基类可以提供 `prepare_request` 等通用逻辑。

---

### 2. 消息模型的“自举”解析 (ContentPart Registry)

处理多模态和复杂内容（如思考过程、工具调用）时，如何将 JSON 转换为正确的类是一个难点。

#### 模式：ContentPart 注册表 (kosong)
利用 Pydantic 和类注册表实现自动分发。

```python
class ContentPart(BaseModel, ABC, MergeableMixin):
    __content_part_registry: ClassVar[dict[str, type["ContentPart"]]] = {}
    type: str

    def __init_subclass__(cls, **kwargs: Any) -> None:
        cls.__content_part_registry[cls.type] = cls

    @classmethod
    def __get_pydantic_core_schema__(cls, ...):
        # 根据 'type' 字段动态校验并实例化子类
        ...
```

**设计理由**：
- **可扩展性**：新增内容类型（如 `VideoPart`）只需子类化，无需修改核心解析代码。
- **强类型**：上层业务逻辑可以直接使用 `isinstance(part, TextPart)`。

---

### 3. 流式响应的片段合并 (Delta Merging)

不同 Provider 的流式输出格式各异，且通常是增量的片段。

#### 模式：就地合并 (MergeableMixin)
kosong 采用 `merge_in_place` 模式，在流式迭代中实时更新消息快照。

```python
class TextPart(ContentPart):
    @override
    def merge_in_place(self, other: Any) -> bool:
        if not isinstance(other, TextPart):
            return False
        self.text += other.text
        return True
```

#### 模式：快照事件 (Pi AI / pydantic-ai)
每个事件都携带当前已完成的 `partial` 消息对象。

**权衡**：
- **就地合并**：内存占用低，适合超长文本，但状态管理较复杂。
- **快照事件**：对 UI 极其友好（直接渲染快照），但每次事件都会克隆对象，大数据量下有开销。

---

### 4. 模型能力画像 (Model Profile)

为了避免在运行时因模型不支持某功能（如 `tool_choice`）而报错，需要静态的能力描述。

#### 模式：声明式 Profile (pydantic-ai)

```python
@dataclass
class ModelProfile:
    supports_tools: bool = True
    supports_json_schema_output: bool = False
    native_output_requires_schema_in_instructions: bool = False
    json_schema_transformer: type[JsonSchemaTransformer] | None = None
```

**设计理由**：
- **预校验**：在发送请求前拦截不支持的操作。
- **智能适配**：如果模型不支持 `tool_choice: required`，框架可以自动降级或修改 Prompt。

---

## 比较矩阵

| 维度 | pydantic-ai | kosong | agentscope |
|------|-------------|--------|------------|
| **抽象层级** | 高 (Agent 级) | 中 (LLM 协议级) | 低 (模型调用级) |
| **消息模型** | ModelMessage (Flat) | Message (ContentPart) | dict-based |
| **流式处理** | StreamedResponse (Event) | StreamedMessage (Merge) | AsyncGenerator |
| **工具抽象** | ToolDefinition | Tool Protocol | dict list |
| **主要特色** | 类型安全, ModelProfile | 协议化, 轻量级 | 简单直观, 支持大量私有模型 |

---

## 最佳实践

1. **协议优先**：尽可能使用 Python `Protocol` 定义 Provider，减少框架侵入性。
2. **显式处理 Token 缓存**：在 TokenUsage 中区分 `input_cache_read` 和 `input_cache_creation`，这对于成本优化至关重要。
3. **提供定制钩子**：Provider 抽象层应暴露 `customize_request_parameters`，因为不同 Provider 对 JSON Schema 的严格程度（Strict Mode）支持不一。
4. **避免抽象泄漏**：尽量不要在 `ChatProvider` 接口中暴露 Provider 特有的参数（如 `top_p`），而应通过 `ModelSettings` 字典透传。
5. **反模式**：
    - **硬编码 Provider 判断**：避免在核心逻辑中使用 `if provider == 'openai'`，应通过 `ModelProfile` 的布尔标记来驱动分支逻辑。
    - **丢弃原始响应**：抽象层应始终保留 `provider_details` 或 `raw_response` 字段，以便于调试和审计。

---

## 相关文档

- [五大 LLM 抽象层框架设计理念对比](./llm-abstraction-comparison.md) - 更广维度的对比
- [Kimi-CLI 架构分析](../architecture/kimi-cli-architecture.md) - kosong 的具体应用
- [Codex LLM 抽象设计](../architecture/codex-llm-abstraction.md) - 另一个轻量级实现参考

---

## 参考

- [pydantic-ai models source](https://github.com/pydantic/pydantic-ai/tree/main/pydantic_ai_slim/pydantic_ai/models)
- [kosong chat_provider source](https://github.com/MoonshotAI/kimi-cli/tree/main/packages/kosong/src/kosong/chat_provider)
- [OpenTelemetry GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/attributes-registry/gen-ai/)

---

*创建时间：2026-03-04*
*更新时间：2026-03-04*
