# 五大框架 WebSocket 流式通讯支持性分析

> **Related topics**: [[streaming-comparison]], [[llm-abstraction-comparison]]

## 概述

WebSocket 是实时 AI 应用的核心通讯方式。本文分析五个框架在 WebSocket 场景下的支持性，包括：

- **消息序列化**：框架事件如何映射到 WebSocket 消息
- **双向通讯**：如何处理客户端中断、打字指示等
- **连接管理**：心跳、重连、超时处理
- **性能考量**：内存占用、延迟、并发能力

---

## WebSocket 场景的核心需求

```
┌─────────────────────────────────────────────────────────────────┐
│                     WebSocket 流式交互模型                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Client ────────> WS Server ────────> LLM Provider              │
│     │                  │                    │                   │
│     │  1. send msg     │  2. generate      │                   │
│     │                  │                    │                   │
│     │  4. recv chunk   │  3. stream chunks │                   │
│     │  4. recv chunk   │                   │                   │
│     │  4. recv tool    │                   │                   │
│     │  4. recv result  │                   │                   │
│     │  4. recv end     │                   │                   │
│     ▼                  ▼                   ▼                   │
│                                                                 │
│  需要支持：                                                       │
│  - 实时文本流式 (text delta)                                     │
│  - 工具调用流式 (tool_call delta -> execute -> result)            │
│  - 结构化输出流式 (JSON delta)                                    │
│  - 取消/中断 (client disconnect / stop signal)                   │
│  - 心跳保活 (ping/pong)                                          │
└─────────────────────────────────────────────────────────────────┘
```

---

## 1. kosong - Callback 驱动的 WebSocket 完美适配

### 架构适配性

kosong 的 **Callback 机制** 天生适合 WebSocket 的推模式：

```python
# kosong WebSocket 集成示例
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    
    kimi = Kimi(model="kimi-k2-turbo-preview", api_key="...")
    history: list[Message] = []
    
    async def on_message_part(part: StreamedMessagePart):
        """每个片段到达立即推送到客户端"""
        if isinstance(part, TextPart):
            await websocket.send_json({
                "type": "text_delta",
                "content": part.text
            })
        elif isinstance(part, ThinkPart):
            await websocket.send_json({
                "type": "thinking_delta", 
                "content": part.think
            })
        elif isinstance(part, ToolCall):
            await websocket.send_json({
                "type": "tool_call",
                "tool": part.function.name,
                "args": part.function.arguments
            })
    
    async def on_tool_result(result: ToolResult):
        """工具执行完成推送结果"""
        await websocket.send_json({
            "type": "tool_result",
            "tool_call_id": result.tool_call_id,
            "output": result.output
        })
    
    # 接收用户消息
    data = await websocket.receive_json()
    history.append(Message(role="user", content=data["message"]))
    
    # 执行生成，流式推送
    result = await kosong.step(
        chat_provider=kimi,
        system_prompt="You are a helpful assistant.",
        toolset=toolset,
        history=history,
        on_message_part=on_message_part,  # 实时推送
        on_tool_result=on_tool_result,    # 工具结果推送
    )
    
    # 发送完成标记
    await websocket.send_json({
        "type": "done",
        "usage": result.usage.model_dump() if result.usage else None
    })
```

### WebSocket 消息协议映射

| kosong 事件 | WebSocket 消息类型 | 适用场景 |
|-------------|-------------------|----------|
| `TextPart` | `text_delta` | 实时打字机效果 |
| `ThinkPart` | `thinking_delta` | 展示推理过程 |
| `ToolCall` | `tool_call` | 显示正在调用工具 |
| `ToolResult` | `tool_result` | 显示工具返回 |
| `GenerateResult` | `done` | 生成完成 |

### 取消/中断支持

```python
# 优雅取消支持
async def websocket_endpoint(websocket: WebSocket):
    task: asyncio.Task | None = None
    
    async def generate_task():
        try:
            result = await kosong.step(
                chat_provider=kimi,
                ...,
                on_message_part=on_message_part,
            )
        except asyncio.CancelledError:
            # 清理资源，通知客户端
            await websocket.send_json({"type": "cancelled"})
            raise
    
    # 启动生成任务
    task = asyncio.create_task(generate_task())
    
    # 监听客户端消息（支持中断）
    try:
        while True:
            data = await websocket.receive_json()
            if data.get("action") == "stop":
                task.cancel()  # 取消生成
                break
    except WebSocketDisconnect:
        task.cancel()
```

### 优势与局限

| 维度 | 评分 | 说明 |
|------|------|------|
| **延迟** | ⭐⭐⭐⭐⭐ | Callback 机制，零缓冲延迟 |
| **内存** | ⭐⭐⭐⭐⭐ | 不缓存所有片段，即来即推 |
| **复杂度** | ⭐⭐⭐⭐ | 简单直接，无需额外适配层 |
| **双向通讯** | ⭐⭐⭐ | 需自己实现中断/心跳 |
| **结构化输出** | ⭐⭐⭐ | 需自行解析和验证 |

---

## 2. republic - 事件流的 WebSocket 映射

### 架构适配性

republic 提供 **StreamEvents** 包装器，适合结构化事件推送：

```python
# republic WebSocket 集成示例
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    
    llm = LLM(model="openai:gpt-5", api_key="...")
    
    # 使用 stream_events 获取结构化事件
    events = llm.stream_events(
        prompt="What is the weather in Tokyo?",
        tools=[get_weather],
        auto_call_tools=True,
    )
    
    for event in events:
        # 直接映射到 WebSocket 消息
        await websocket.send_json({
            "type": event.kind,  # text, tool_call, tool_result, usage, error, final
            "data": event.data
        })
        
        # 处理中断信号
        if await check_client_disconnect(websocket):
            break
```

### 事件类型映射

| republic Event | WebSocket 消息 | 数据内容 |
|----------------|---------------|----------|
| `text` | `text_delta` | `{"content": "..."}` |
| `tool_call` | `tool_call` | `{"index": 0, "call": {...}}` |
| `tool_result` | `tool_result` | `{"index": 0, "result": ...}` |
| `usage` | `usage` | `{"input_tokens": ..., "output_tokens": ...}` |
| `error` | `error` | `{"kind": "...", "message": "..."}` |
| `final` | `done` | `{"text": ..., "tool_calls": [...]}` |

### 统一的事件处理模式

```python
async def handle_republic_stream(websocket: WebSocket, llm: LLM, prompt: str):
    """统一的 republic 流式处理"""
    
    stream = llm.stream_events_async(
        prompt=prompt,
        tools=available_tools,
    )
    
    async for event in stream:
        # 统一的消息格式
        message = {
            "event_id": generate_event_id(),
            "timestamp": datetime.utcnow().isoformat(),
            "type": event.kind,
            "payload": event.data,
            "metadata": {
                "model": llm.model,
                "provider": llm.provider,
            }
        }
        
        await websocket.send_json(message)
        
        # 客户端中断检测
        if websocket.client_state == WebSocketState.DISCONNECTED:
            # republic 的 stream 需要手动中断
            break
```

### 优势与局限

| 维度 | 评分 | 说明 |
|------|------|------|
| **延迟** | ⭐⭐⭐⭐ | 事件级推送，略逊于 callback |
| **内存** | ⭐⭐⭐⭐ | StreamEvent 轻量 |
| **复杂度** | ⭐⭐⭐⭐ | 统一事件格式，易于处理 |
| **双向通讯** | ⭐⭐⭐ | 需自行实现中断 |
| **结构化输出** | ⭐⭐⭐⭐ | `final` 事件包含完整结果 |

### 与 kosong 的对比

```
kosong:    Callback 推模式 ─────> WebSocket send
                    │
                    └──── 延迟最低，代码分散

republic:  StreamEvents 拉模式 ──> WebSocket send  
                    │
                    └──── 统一事件格式，易于调试
```

---

## 3. litai - 透传流的 WebSocket 极简集成

### 架构适配性

litai 最简单，直接透传 `Iterator[str]`：

```python
# litai WebSocket 集成示例
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    
    llm = LLM(model="openai/gpt-5", api_key="...")
    
    # 最简单的流式处理
    for chunk in llm.chat("Hello", stream=True):
        await websocket.send_json({
            "type": "text_delta",
            "content": chunk
        })
    
    await websocket.send_json({"type": "done"})
```

### 批量发送优化

```python
async def optimized_litai_stream(websocket: WebSocket, llm: LLM, prompt: str):
    """litai 批量发送优化版"""
    
    buffer = []
    last_send = time.time()
    
    for chunk in llm.chat(prompt, stream=True):
        buffer.append(chunk)
        
        # 批处理：累积 50ms 或 100 字符发送
        if time.time() - last_send > 0.05 or len(''.join(buffer)) > 100:
            await websocket.send_json({
                "type": "text_delta",
                "content": ''.join(buffer)
            })
            buffer = []
            last_send = time.time()
    
    # 发送剩余内容
    if buffer:
        await websocket.send_json({
            "type": "text_delta",
            "content": ''.join(buffer)
        })
```

### 工具调用的局限

```python
# litai 的工具调用问题
response = llm.chat(
    "What's the weather?",
    tools=[get_weather],
    auto_call_tools=True,  # 自动执行工具
)
# 返回的是字符串，不是流式！

# 手动处理工具调用才能获得流式
chosen_tool = llm.chat("...", tools=[get_weather])  # 获取工具选择
# 但这不是流式的，是一次性返回
```

### 优势与局限

| 维度 | 评分 | 说明 |
|------|------|------|
| **延迟** | ⭐⭐⭐ | 需要批处理优化，否则消息过多 |
| **内存** | ⭐⭐⭐⭐ | 简单，无额外开销 |
| **复杂度** | ⭐⭐⭐⭐⭐ | 最简单 |
| **双向通讯** | ⭐⭐⭐ | 需自行实现 |
| **工具流式** | ⭐⭐ | 不支持 |

---

## 4. pydantic-ai - 完整事件系统的 WebSocket 专业方案

### 架构适配性

pydantic-ai 提供 **最完整的流式事件系统**，专为复杂 UI 设计：

```python
# pydantic-ai WebSocket 集成示例
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    
    agent = Agent('openai:gpt-5', tools=[get_weather])
    
    # 使用 run_stream_events 获取完整事件流
    async for event in agent.run_stream_events("What's the weather in Tokyo?"):
        # 直接序列化 pydantic 事件
        await websocket.send_json({
            "type": event.__class__.__name__,
            "data": event_to_dict(event)
        })
```

### 完整的事件类型映射

| pydantic-ai Event | WebSocket Type | 说明 |
|-------------------|----------------|------|
| `PartStartEvent` | `part_start` | 新 part 开始 |
| `PartDeltaEvent` | `part_delta` | part 更新 |
| `PartEndEvent` | `part_end` | part 完成 |
| `FinalResultEvent` | `final_result` | 结果匹配 |
| `FunctionToolCallEvent` | `tool_call` | 函数工具调用 |
| `FunctionToolResultEvent` | `tool_result` | 工具结果 |
| `TextPart` | `text` | 文本内容 |
| `ToolCallPart` | `tool_call` | 工具调用 |

### 专业的 UI 流式适配

```python
from pydantic_ai.ui import AgentUIAdapter

async def advanced_websocket_handler(websocket: WebSocket):
    """使用 pydantic-ai 的 UI 适配器"""
    await websocket.accept()
    
    agent = Agent('openai:gpt-5', tools=[...])
    
    # AgentUIAdapter 自动处理 WebSocket 协议
    adapter = AgentUIAdapter(
        agent=agent,
        output_mode="structured",  # 或 "text"
    )
    
    async for message in websocket.iter_json():
        # 适配器自动转换事件并处理双向通讯
        async for event in adapter.handle_message(message):
            await websocket.send_json(event.to_protocol_dict())
```

### Vercel AI SDK 兼容模式

```python
# pydantic-ai 原生支持 Vercel AI SDK 协议
from pydantic_ai.ui.vercel_ai import VercelAIStreamAdapter

async def vercel_compatible_endpoint(websocket: WebSocket):
    await websocket.accept()
    
    agent = Agent('openai:gpt-5')
    adapter = VercelAIStreamAdapter(agent)
    
    # 自动输出 Vercel AI SDK 格式的流
    async for chunk in adapter.run_stream("Hello"):
        # 0:"Hello"  (text)
        # d:{"finishReason": "stop"}  (done)
        await websocket.send_text(chunk)
```

### Agent 编排的 WebSocket 支持

```python
# 多 Agent 编排 + WebSocket
async def multi_agent_websocket(websocket: WebSocket):
    await websocket.accept()
    
    parent = Agent('openai:gpt-5')
    child = Agent('openai:gpt-5-mini')
    
    async with parent.run_stream("Complex task") as stream:
        async for event in stream:
            # 可以动态切换 Agent
            if needs_delegation(event):
                async with child.run_stream("Subtask") as child_stream:
                    async for child_event in child_stream:
                        await websocket.send_json({
                            "agent": "child",
                            "event": child_event_to_dict(child_event)
                        })
            
            await websocket.send_json({
                "agent": "parent",
                "event": event_to_dict(event)
            })
```

### 优势与局限

| 维度 | 评分 | 说明 |
|------|------|------|
| **延迟** | ⭐⭐⭐⭐ | 事件丰富但有 overhead |
| **内存** | ⭐⭐⭐ | PartsManager 有状态 |
| **复杂度** | ⭐⭐⭐ | 学习曲线陡峭 |
| **双向通讯** | ⭐⭐⭐⭐⭐ | UI 适配器专业支持 |
| **结构化输出** | ⭐⭐⭐⭐⭐ | 原生支持，自动验证 |

---

## 5. LangChain - Callback 的 WebSocket 专业方案

### 核心架构：推模式（Callback）为主，拉模式（astream）为辅

LangChain 的 **Callback 系统** 天生为 WebSocket 推模式设计：

```python
# LangChain WebSocket 集成示例
from langchain_core.callbacks import AsyncCallbackHandler

class WebSocketCallbackHandler(AsyncCallbackHandler):
    """WebSocket 实时推送处理器"""
    
    def __init__(self, websocket: WebSocket):
        self.websocket = websocket
        self.tokens: list[str] = []
    
    async def on_llm_new_token(
        self,
        token: str,
        *,
        chunk: ChatGenerationChunk | None = None,
        run_id: UUID,
        **kwargs: Any,
    ) -> None:
        """每个 token 产生时立即推送到客户端"""
        self.tokens.append(token)
        await self.websocket.send_json({
            "type": "text_delta",
            "content": token,
            "run_id": str(run_id),
        })
    
    async def on_llm_end(
        self,
        response: LLMResult,
        *,
        run_id: UUID,
        **kwargs: Any,
    ) -> None:
        """LLM 生成结束时发送完成标记"""
        full_text = "".join(self.tokens)
        await self.websocket.send_json({
            "type": "done",
            "content": full_text,
            "usage": response.llm_output.get("token_usage"),
        })
    
    async def on_tool_start(
        self,
        serialized: dict[str, Any],
        input_str: str,
        *,
        run_id: UUID,
        **kwargs: Any,
    ) -> None:
        """工具开始执行时通知客户端"""
        await self.websocket.send_json({
            "type": "tool_start",
            "tool": serialized.get("name"),
            "input": input_str,
        })
    
    async def on_tool_end(
        self,
        output: str,
        *,
        run_id: UUID,
        **kwargs: Any,
    ) -> None:
        """工具执行完成推送结果"""
        await self.websocket.send_json({
            "type": "tool_result",
            "output": output,
        })

# WebSocket 端点使用
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    
    # 创建带 Callback 的 Chain
    handler = WebSocketCallbackHandler(websocket)
    
    try:
        while True:
            # 接收客户端消息
            data = await websocket.receive_json()
            user_input = data["message"]
            
            # 执行 Chain，Callback 自动推送流式结果
            await chain.ainvoke(
                {"input": user_input},
                config={"callbacks": [handler]},
            )
            
    except WebSocketDisconnect:
        pass
```

### WebSocket 消息协议映射

| LangChain 回调 | WebSocket 消息类型 | 数据内容 |
|----------------|-------------------|----------|
| `on_llm_new_token` | `text_delta` | `{"content": "...", "run_id": "..."}` |
| `on_llm_end` | `done` | `{"content": "...", "usage": {...}}` |
| `on_tool_start` | `tool_start` | `{"tool": "...", "input": "..."}` |
| `on_tool_end` | `tool_result` | `{"output": "..."}` |
| `on_chain_error` | `error` | `{"error": "...", "run_id": "..."}` |

### 双模式灵活切换

```python
class FlexibleWebSocketHandler:
    """根据场景灵活选择推模式或拉模式"""
    
    def __init__(self, websocket: WebSocket, mode: str = "push"):
        self.websocket = websocket
        self.mode = mode
    
    async def handle_push(self, message: str):
        """推模式：Callback 驱动，零延迟"""
        handler = WebSocketCallbackHandler(self.websocket)
        await chain.ainvoke(
            {"input": message},
            config={"callbacks": [handler]},
        )
    
    async def handle_pull(self, message: str):
        """拉模式：Iterator 驱动，支持背压"""
        async for chunk in chain.astream({"input": message}):
            await self.websocket.send_json({
                "type": "chunk",
                "content": chunk.content if hasattr(chunk, 'content') else str(chunk),
            })
            # 背压控制
            await asyncio.sleep(0.01)

# 客户端控制模式切换
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    handler = FlexibleWebSocketHandler(websocket)
    
    while True:
        data = await websocket.receive_json()
        mode = data.get("mode", "push")
        message = data["message"]
        
        if mode == "push":
            await handler.handle_push(message)
        else:
            await handler.handle_pull(message)
```

### 取消/中断支持

```python
class CancellableChainHandler:
    """支持取消的 LangChain 处理器"""
    
    def __init__(self):
        self.current_task: asyncio.Task | None = None
    
    async def handle_message(self, websocket: WebSocket, message: str):
        """处理消息，支持取消"""
        # 取消之前的任务
        if self.current_task and not self.current_task.done():
            self.current_task.cancel()
            try:
                await self.current_task
            except asyncio.CancelledError:
                pass
        
        # 启动新任务
        self.current_task = asyncio.create_task(
            self._run_chain(websocket, message)
        )
    
    async def _run_chain(self, websocket: WebSocket, message: str):
        try:
            handler = WebSocketCallbackHandler(websocket)
            await chain.ainvoke(
                {"input": message},
                config={"callbacks": [handler]},
            )
        except asyncio.CancelledError:
            await websocket.send_json({"type": "cancelled"})
            raise

# WebSocket 端点
handler = CancellableChainHandler()

async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    
    while True:
        data = await websocket.receive_json()
        
        if data.get("action") == "stop":
            # 客户端发送停止信号
            if handler.current_task:
                handler.current_task.cancel()
        else:
            # 处理新消息
            await handler.handle_message(websocket, data["message"])
```

### 优势与局限

| 维度 | 评分 | 说明 |
|------|------|------|
| **延迟** | ⭐⭐⭐⭐⭐ | Callback 推模式，零缓冲延迟 |
| **内存** | ⭐⭐⭐⭐ | 消息块可累加，但不过度缓存 |
| **复杂度** | ⭐⭐⭐ | 需要理解 Callback 和 Iterator 两种模式 |
| **双向通讯** | ⭐⭐⭐⭐ | 通过 task 取消实现中断 |
| **结构化输出** | ⭐⭐⭐⭐⭐ | `astream_events` 提供完整中间步骤 |
| **生态系统** | ⭐⭐⭐⭐⭐ | 几百个集成，社区最活跃 |

### 与 kosong 的对比

| 特性 | kosong | LangChain |
|------|--------|-----------|
| **模式** | Callback 单模式 | Callback + Iterator 双模式 |
| **WebSocket 适配** | 天然适合 | 同样适合，但更灵活 |
| **片段合并** | `merge_in_place` 就地 | `__add__` 函数式累加 |
| **中间步骤** | 需自行实现 | `astream_events` 原生支持 |
| **生态系统** | 轻量，内置 | 丰富，几百个集成 |
| **学习曲线** | 平缓 | 较陡（概念多） |

---

## 综合对比：WebSocket 支持性

### 实时性对比

```
延迟从低到高：

kosong      ████████████████████  Callback 零延迟
LangChain   ███████████████████░  Callback 零延迟（推模式）
republic    █████████████████░░░  事件级延迟  
pydantic-ai ██████████████░░░░░░  丰富事件 overhead
litai       ██████████░░░░░░░░░░  需批处理优化
```

### WebSocket 消息密度

```
消息数量（相同内容）：

kosong      ████████████████████████████████████████  每片段一条
LangChain   █████████████████████████████████████░░░  Callback 每条 token
republic    ██████████████████████████████░░░░░░░░░░  合并后事件
litai       ██████████████████████░░░░░░░░░░░░░░░░░░  批处理后
pydantic-ai ██████████████████████████████░░░░░░░░░░  事件丰富
```

### 实现复杂度

```python
# 复杂度排名（代码行数估算）

# litai - 最简单 (5 行)
for chunk in llm.chat(prompt, stream=True):
    await ws.send({"type": "text", "content": chunk})

# republic - 简单 (10 行)
for event in llm.stream_events(prompt):
    await ws.send({"type": event.kind, "data": event.data})

# kosong - 中等 (15 行)
async def on_part(p):
    await ws.send({"type": type(p).__name__, "data": p.model_dump()})
await kosong.step(..., on_message_part=on_part)

# LangChain - 中等 (15-20 行，但概念多)
class Handler(AsyncCallbackHandler):
    async def on_llm_new_token(self, token, **kwargs):
        await ws.send({"type": "token", "content": token})
await chain.ainvoke(..., config={"callbacks": [Handler()]})

# pydantic-ai - 复杂 (20+ 行)
async for event in agent.run_stream_events(prompt):
    await ws.send({"type": event.__class__.__name__, "data": event_to_dict(event)})
```

---

## 推荐方案

### 根据场景选择

| 场景 | 推荐框架 | 理由 |
|------|----------|------|
| **低延迟聊天** | kosong / LangChain | Callback 机制，最低延迟 |
| **复杂 Agent UI** | pydantic-ai / LangChain | 完整事件系统，UI 适配器 |
| **快速原型** | litai | 最简单，5 分钟上手 |
| **审计合规** | republic | 结构化事件，易于记录 |
| **Vercel AI SDK** | pydantic-ai | 原生兼容 |
| **多模态流式** | pydantic-ai | 支持 image/audio/video delta |
| **丰富生态集成** | LangChain | 几百个集成，Callback 最完善 |
| **推/拉双模式** | LangChain | Callback + Iterator 灵活切换 |

### WebSocket 协议设计建议

基于四个框架的最佳实践，推荐的 WebSocket 消息协议：

```typescript
// 统一的 WebSocket 协议接口
interface WSMessage {
  event_id: string;        // 唯一标识
  timestamp: string;       // ISO 8601
  type: MessageType;       // 消息类型
  payload: unknown;        // 数据负载
  metadata?: {             // 元数据
    model?: string;
    provider?: string;
    usage?: TokenUsage;
  };
}

type MessageType = 
  | "text_delta"           // 文本片段
  | "thinking_delta"       // 推理片段
  | "tool_call_start"      // 工具调用开始
  | "tool_call_delta"      // 工具参数片段
  | "tool_call_end"        // 工具调用完成
  | "tool_result"          // 工具执行结果
  | "structured_delta"     // 结构化输出片段
  | "error"                // 错误
  | "done";                // 完成
```

---

## 相关文件

- kosong: `kimi-cli/packages/kosong/src/kosong/`
  - `__init__.py` - step() callback 机制
  - `message.py` - StreamedMessagePart 类型
  
- republic: `republic/src/republic/`
  - `core/results.py` - StreamEvents 定义
  
- litai: `litai/src/litai/`
  - `llm.py` - stream 参数实现
  
- pydantic-ai: `pydantic-ai/pydantic_ai_slim/pydantic_ai/`
  - `agent/abstract.py` - run_stream_events()
  - `ui/` - WebSocket 适配器
  - `messages.py` - 事件类型定义

- LangChain: `langchain/libs/core/langchain_core/`
  - `callbacks/base.py` - AsyncCallbackHandler 基类
  - `tracers/event_stream.py` - astream_events 实现
  - `runnables/base.py` - Runnable astream() 方法

---

*Last updated: 2026-02-25*
