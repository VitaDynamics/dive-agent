# OpenAI Responses WebSocket 与四框架对比分析

> **Related topics**: [[websocket-streaming-support]], [[streaming-comparison]]

## 概述

OpenAI 于 2025 年推出的 Responses WebSocket API (`responses_websockets=2026-02-06`) 代表了 LLM 流式通讯的最新标准。本文分析其核心设计，并与 kosong、republic、litai、pydantic-ai 四个框架进行对比。

---

## 1. OpenAI Responses WebSocket 核心设计

### 1.1 连接模型

```python
# OpenAI WebSocket 连接模型
from openai import OpenAI

client = OpenAI()

# 建立持久 WebSocket 连接
with client.responses.connect(
    extra_headers={"OpenAI-Beta": "responses_websockets=2026-02-06"}
) as connection:
    # 在连接内执行多次交互
    for turn in demo_turns:
        result = run_turn(connection, ...)
```

**关键特性**：
- **长连接复用**：单个 WebSocket 连接支持多轮对话
- **状态保持**：`previous_response_id` 链式关联上下文
- **双向通讯**：可以在流式过程中发送中断/控制信号

### 1.2 事件流模型

```python
# OpenAI 的事件流处理方式
connection.response.create(
    model=model,
    input=input_payload,
    stream=True,
    previous_response_id=previous_response_id,
    tools=tools,
    tool_choice=tool_choice,
)

for event in connection:
    # 细粒度事件类型
    if event.type == "response.output_text.delta":
        text_parts.append(event.delta)
    elif event.type == "response.output_item.done":
        if event.item.type == "function_call":
            function_calls.append(...)
    elif event.type == "response.done":
        response_id = event.response.id
        break
```

**事件类型体系**：

| 事件类型 | 说明 | 对应框架概念 |
|----------|------|--------------|
| `response.output_text.delta` | 文本片段 | kosong `TextPart` / pydantic-ai `TextPartDelta` |
| `response.output_item.done` | 输出项完成 | pydantic-ai `PartEndEvent` |
| `response.function_call` | 工具调用 | republic `tool_call` / pydantic-ai `ToolCallPart` |
| `response.done` | 响应完成 | republic `final` / pydantic-ai `FinalResultEvent` |
| `error` | 错误 | 所有框架的错误类型 |

### 1.3 工具调用流式处理

```python
# OpenAI 的流式工具调用循环
while True:
    # 1. 发送请求（可能是文本或工具输出）
    connection.response.create(...)
    
    # 2. 迭代接收事件
    for event in connection:
        if event.type == "response.output_text.delta":
            # 收集文本片段
            
        elif event.type == "response.output_item.done" and event.item.type == "function_call":
            # 3. 收集工具调用请求
            function_calls.append(...)
            
        elif event.type in ("response.completed", "response.done"):
            response_id = event.response.id
            break
    
    # 4. 如果有工具调用，执行工具并循环
    if function_calls:
        tool_outputs = execute_tools(function_calls)
        input_payload = tool_outputs  # 下一轮输入是工具输出
        tool_choice = "none"  # 强制模型处理工具结果
        continue
    
    break  # 没有工具调用，结束
```

**关键设计**：
- 同一连接内循环处理多轮（文本 → 工具调用 → 工具结果 → 文本）
- `previous_response_id` 自动维护对话上下文
- `tool_choice` 控制模型行为（强制调用/禁止调用/自动）

---

## 2. 四框架与 OpenAI WebSocket 的对比

### 2.1 连接模型对比

```
┌─────────────────────────────────────────────────────────────────────┐
│                        连接模型对比                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  OpenAI WebSocket                                                    │
│  ┌─────────────────────────────────────────────────────────┐        │
│  │  WS Connection                                          │        │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐                 │        │
│  │  │ Turn 1  │→ │ Turn 2  │→ │ Turn 3  │  ...             │        │
│  │  └─────────┘  └─────────┘  └─────────┘                 │        │
│  │       ↑ previous_response_id 链式关联                    │        │
│  └─────────────────────────────────────────────────────────┘        │
│                              长连接，状态保持                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  kosong / pydantic-ai / republic / litai                            │
│  ┌─────────┐    ┌─────────┐    ┌─────────┐                         │
│  │ HTTP 1  │    │ HTTP 2  │    │ HTTP 3  │  ...                    │
│  └─────────┘    └─────────┘    └─────────┘                         │
│       ↑ history 数组传递上下文                                       │
│                              短连接，无状态                            │
└─────────────────────────────────────────────────────────────────────┘
```

| 特性 | OpenAI WS | 四框架 HTTP |
|------|-----------|-------------|
| **连接方式** | 长连接 WebSocket | 短连接 HTTP/HTTPS |
| **状态管理** | `previous_response_id` | `history` 数组 |
| **上下文传递** | 服务端自动维护 | 客户端显式传递 |
| **中断能力** | 原生支持（发送 cancel 信号） | 依赖 HTTP 取消 |
| **延迟** | 低（无连接建立开销） | 高（每次握手） |

### 2.2 事件模型对比

```python
# OpenAI 事件模型 - 基于类型的细粒度事件
for event in connection:
    match event.type:
        case "response.output_text.delta":
            handle_text(event.delta)
        case "response.output_item.done":
            if event.item.type == "function_call":
                handle_tool_call(event.item)
        case "response.done":
            handle_complete(event.response.id)
```

```python
# kosong - Callback 模式（推模式）
async def on_message_part(part: StreamedMessagePart):
    if isinstance(part, TextPart):
        handle_text(part.text)
    elif isinstance(part, ToolCall):
        handle_tool_call(part)

await kosong.step(..., on_message_part=on_message_part)
```

```python
# republic - 统一事件流
for event in llm.stream_events(...):
    match event.kind:
        case "text": handle_text(event.data["content"])
        case "tool_call": handle_tool_call(event.data["call"])
        case "final": handle_complete(event.data)
```

```python
# pydantic-ai - 完整事件系统
async for event in agent.run_stream_events(...):
    match event:
        case PartDeltaEvent():
            handle_delta(event.delta)
        case PartEndEvent():
            handle_end(event.part)
        case FunctionToolCallEvent():
            handle_tool_call(event.part)
```

**事件粒度对比**：

| 框架 | 事件粒度 | 优点 | 缺点 |
|------|----------|------|------|
| **OpenAI** | 细粒度（delta/done） | 精确控制 | 事件类型多 |
| **kosong** | 逻辑单元（Part） | 简洁高效 | 信息略少 |
| **republic** | 业务事件（6种） | 清晰易懂 | 粒度中等 |
| **pydantic-ai** | 最细（Start/Delta/End） | 最完整 | 复杂度高 |
| **litai** | 无（原始字符串） | 最简单 | 功能弱 |

### 2.3 工具调用流式对比

```python
# OpenAI WebSocket - 连接内循环处理
with client.responses.connect() as connection:
    current_input = "初始提示"
    while True:
        # 发送请求
        connection.response.create(
            input=current_input,
            previous_response_id=prev_id,
            ...
        )
        
        # 接收响应和工具调用
        function_calls = []
        for event in connection:
            if is_tool_call(event):
                function_calls.append(extract_call(event))
        
        # 如果有工具调用，执行并继续循环
        if function_calls:
            outputs = execute_tools(function_calls)
            current_input = outputs  # 下一轮输入
            continue
        
        break
```

```python
# kosong - 异步 Future 模式
tool_result_futures = {}

async def on_tool_call(tool_call: ToolCall):
    result = toolset.handle(tool_call)
    if isinstance(result, ToolResultFuture):
        tool_result_futures[tool_call.id] = result

await kosong.step(..., on_tool_call=on_tool_call)
results = await asyncio.gather(*tool_result_futures.values())
```

```python
# pydantic-ai - Agent Graph 编排
async with agent.run_stream("...") as stream:
    async for event in stream:
        if isinstance(event, FunctionToolCallEvent):
            # 工具调用在 Graph 内部处理
            # 结果自动流入下一轮
            pass
```

**工具调用模式对比**：

| 模式 | 代表 | 特点 |
|------|------|------|
| **连接内循环** | OpenAI | 显式控制每轮交互 |
| **Callback + Future** | kosong | 异步并行执行 |
| **Graph 编排** | pydantic-ai | 自动处理工具链 |
| **自动执行** | republic | 简化版工具链 |

---

## 3. WebSocket 设计模式演进

### 3.1 三代流式 API 演进

```
第一代：HTTP SSE (Server-Sent Events)
├── litai ────────────────────────────────> Iterator[str]
├── 简单，单向，短连接
└── 示例：for chunk in llm.chat(..., stream=True):

第二代：HTTP 流式 + 结构化事件
├── republic ─────────────────────────────> StreamEvents
├── pydantic-ai ──────────────────────────> StreamedResponse
├── 事件驱动， richer 语义
└── 示例：for event in llm.stream_events(...):

第三代：WebSocket 双向流式
├── OpenAI Responses WS ──────────────────> WebSocket Connection
├── 长连接，双向通讯，状态保持
└── 示例：with client.responses.connect() as conn:
```

### 3.2 OpenAI WebSocket 对框架的启示

**kosong 可以借鉴的**：
- Callback 模式可以扩展支持 WebSocket 的推模式
- `previous_response_id` 概念可以引入到对话管理中

**republic 可以借鉴的**：
- StreamEvents 与 OpenAI 事件模型非常接近
- 可以很容易封装 OpenAI WS 连接

**pydantic-ai 可以借鉴的**：
- 已经有完整的事件系统，与 OpenAI WS 事件一一对应
- UI 适配器层可以支持 WebSocket 协议

**litai 可以借鉴的**：
- 简单性仍然有价值，但可能需要增加 WebSocket 支持层

---

## 4. 理想的 WebSocket 抽象设计

基于 OpenAI WebSocket 和四个框架的优点，理想的抽象应该：

```python
# 理想的 WebSocket LLM 客户端抽象

class WSLLMConnection(ABC):
    """WebSocket LLM 连接抽象"""
    
    @abstractmethod
    async def send(self, message: UserMessage) -> None: ...
    
    @abstractmethod
    async def stream(self) -> AsyncIterator[LLMEvent]: ...
    
    @abstractmethod
    async def interrupt(self) -> None: ...
    
    @abstractmethod
    async def close(self) -> None: ...

# 使用示例
async with WSLLMClient.connect("wss://api.openai.com/v1/responses") as conn:
    # 发送消息
    await conn.send(UserMessage(content="Hello"))
    
    # 流式接收事件
    async for event in conn.stream():
        match event:
            case TextDelta(text=txt):
                await websocket.send({"type": "text", "content": txt})
            case ToolCall(name=n, args=a):
                await websocket.send({"type": "tool_call", "name": n, "args": a})
            case Done(response_id=id):
                await websocket.send({"type": "done", "id": id})
```

---

## 5. 四框架 WebSocket 支持度总评（对比 OpenAI 标准）

### 5.1 功能支持矩阵

| 功能 | OpenAI WS | kosong | republic | litai | pydantic-ai |
|------|-----------|--------|----------|-------|-------------|
| **长连接复用** | ✅ | ❌ | ❌ | ❌ | ❌ |
| **双向通讯** | ✅ | ⚠️ | ⚠️ | ⚠️ | ⚠️ |
| **连接内循环** | ✅ | ❌ | ❌ | ❌ | ❌ |
| `previous_response_id` | ✅ | ❌ | ❌ | ❌ | ❌ |
| **细粒度事件** | ✅ | ⚠️ | ✅ | ❌ | ✅ |
| **流式工具调用** | ✅ | ✅ | ⚠️ | ❌ | ✅ |
| **中断/取消** | ✅ | ✅ | ⚠️ | ⚠️ | ✅ |
| **状态保持** | 服务端 | 客户端 | 客户端 | 客户端 | 客户端 |

### 5.2 架构先进性排名

```
WebSocket 架构先进性：

1. OpenAI Responses WS  ████████████████████  第三代，最先进
2. pydantic-ai           ███████████████░░░░░  最接近，有完整事件系统
3. republic              █████████████░░░░░░░  事件模型接近，但 HTTP 短连接
4. kosong                ████████████░░░░░░░░  Callback 模式可适配 WS
5. litai                 ████████░░░░░░░░░░░░  简单，需额外封装层
```

---

## 6. 迁移建议

### 从 HTTP 流式迁移到 WebSocket

```python
# 当前 HTTP 流式（republic 风格）
for event in llm.stream_events(prompt):
    await ws.send(event.to_dict())

# 迁移到 WebSocket 流式
async with llm.ws_connect() as conn:
    await conn.send(prompt)
    async for event in conn.stream():
        await ws.send(event.to_dict())
```

### 四框架的 WebSocket 适配策略

| 框架 | 适配策略 | 预计工作量 |
|------|----------|------------|
| **kosong** | Callback 模式天然适合 WS，需添加连接管理 | 低 |
| **republic** | StreamEvents 可直接映射到 WS 事件 | 低 |
| **litai** | 需要增加 WS 层封装，保持简单性 | 中 |
| **pydantic-ai** | 已有 UI 适配器，扩展支持 WS 协议 | 中 |

---

## 7. 总结

OpenAI Responses WebSocket API 代表了 LLM 流式通讯的**第三代标准**：

1. **从拉模式到推模式**：HTTP SSE → WebSocket 双向
2. **从短连接到长连接**：每次请求握手 → 一次握手多次交互
3. **从客户端状态到服务端状态**：`history` 数组 → `previous_response_id`

四个框架中：
- **pydantic-ai** 的完整事件系统最接近 OpenAI 标准
- **kosong** 的 Callback 机制最适合 WebSocket 推模式
- **republic** 的事件模型与 OpenAI 相似度高
- **litai** 需要较大改动才能支持 WebSocket

**推荐**：新项目优先考虑支持 WebSocket 的架构设计，以获得更低的延迟和更好的实时性。

---

*Last updated: 2026-02-25*
