---
tags: streaming, voice, audio, agentscope, comparison, real-time
---

# AgentScope 中的实时语音处理 (Realtime Voice)

> **范围**：本文档深入研究 AgentScope 如何实现实时语音处理，包括其多模型适配、事件驱动架构以及独特的“语音聊天室”多智能体交互机制。
>
> **综合自**：AgentScope, Pydantic-AI, Kimi-CLI, LangChain
>
> **优先级**：P0

---

## 概述

实时语音交互（Realtime Voice Interaction）是新一代 AI Agent 的核心能力。不同于传统的“文本转语音 (TTS)”或“语音转文本 (ASR)”的串联模式，实时语音要求毫秒级的低延迟响应、全双工通话（双向同时发声）以及实时中断（User Interruption）能力。

AgentScope 通过一套完整的**异步事件驱动架构**实现了这一目标，将前端交互、智能体逻辑与模型 API 彻底解耦，并原生支持了多智能体之间的实时语音对话。

## 问题描述

实现高效的实时语音 Agent 面临以下挑战：
1. **多模型适配**：OpenAI, Gemini 和 DashScope 的实时 API 协议各不相同（WebSocket 消息格式、采样率要求等）。
2. **并发与流式处理**：需要同时处理音频采集、模型推送、工具调用和音频播放，不能阻塞。
3. **多智能体协作**：如何让多个实时语音智能体像人类一样在同一个“房间”里交谈？
4. **延迟控制**：如何减少 ASR -> LLM -> TTS 链路中的感知延迟。

## 核心概念

### 1. 统一事件模型 (Unified Event Model)

#### 框架：AgentScope

AgentScope 定义了三层事件模型来抽象实时交互：
- **ClientEvents**: Web 前端发送给后端的事件（如 `ClientAudioAppendEvent`, `ClientResponseCancelEvent`）。
- **ServerEvents**: 后端（Agent）发送给前端或其它 Agent 的事件（如 `AgentResponseAudioDeltaEvent`）。
- **ModelEvents**: 模型 API 返回的底层事件。

```python
# ServerEvents 的定义示例
class ServerEvents:
    class AgentResponseAudioDeltaEvent(EventBase):
        response_id: str
        item_id: str
        delta: str # Base64 编码的音频片段
        format: AudioFormat # 音频格式信息 (PCM16, 24kHz 等)
        agent_id: str
        agent_name: str
```

**设计理由**：
- **解耦**：Agent 逻辑不需要关心具体的 WebSocket 协议细节。
- **一致性**：无论是 OpenAI 还是 Gemini，对 Agent 暴露的都是统一的 `ServerEvents`。

---

### 2. 异步转发循环 (Asynchronous Forwarding Loops)

#### 框架：AgentScope

`RealtimeAgent` 内部维护了两个核心异步循环：
- **Forward Loop**: 将来自外部（前端或其他智能体）的音频/文本输入转发给模型。
- **Response Loop**: 将模型生成的音频流、文本流和工具调用结果转发给外部。

```python
# _realtime_agent.py 中的 Forward Loop 片段
async def _forward_loop(self) -> None:
    while True:
        event = await self._incoming_queue.get()
        match event:
            case ClientEvents.ClientAudioAppendEvent() as event:
                # 采样率重采样 (Resampling)
                delta = _resample_pcm_delta(event.audio, receive_rate, self.model.input_sample_rate)
                # 推送给模型
                await self.model.send(AudioBlock(source=Base64Source(data=delta)))
```

**设计理由**：
- **非阻塞**：音频处理与逻辑处理异步进行。
- **重采样支持**：内置 `_resample_pcm_delta` 工具，解决不同模型对采样率要求不一的问题（如 DashScope 16kHz, OpenAI 24kHz）。

---

### 3. 多智能体语音聊天室 (Voice Chat Room)

#### 框架：AgentScope

这是 AgentScope 的一大亮点。通过 `ChatRoom` 抽象，多个 `RealtimeAgent` 可以共享同一个音频流上下文。

```python
# _chat_room.py 中的广播逻辑
async def _forward_loop(self, outgoing_queue: Queue) -> None:
    while True:
        event = await self._queue.get()
        if isinstance(event, ServerEvents.EventBase):
            # 1. 转发给前端播放
            await outgoing_queue.put(event)
            # 2. 广播给房间内的其它 Agent
            sender_id = getattr(event, "agent_id", None)
            for agent in self.agents:
                if agent.id != sender_id:
                    await agent.handle_input(event)
```

**设计理由**：
- **实时同步**：当 Agent A 说话时，Agent B 能实时收到音频输入，从而实现“听”和“说”的同步。
- **自然交互**：模拟了真实人类会议室的场景。

---

## 比较矩阵

| 方面 | AgentScope | Pydantic-AI | Kimi-CLI (kosong) | LangChain |
|------|------------|-------------|-------------------|-----------|
| **语音原生支持** | **P0 (RealtimeAgent)** | 无 (主要通过 ASR/TTS 串联) | 无 (主要为文本流式) | P2 (RealtimeChatOpenAI 包装) |
| **实时性** | 极高 (WebSocket 直连) | 中 (HTTP 轮询/流式) | 高 (SSE/WebSocket) | 高 (模型 SDK 包装) |
| **多智能体语音** | **支持 (ChatRoom)** | 不支持 | 不支持 | 不支持 |
| **采样率处理** | 内置重采样工具 | 需自行处理 | 需自行处理 | 需自行处理 |
| **复杂度** | 高 (底层事件驱动) | 低 (装饰器/类型系统) | 中 (轻量级流式) | 中 (工具链集成) |

---

## 最佳实践

1. **采样率匹配**：始终检查模型所需的输入采样率。AgentScope 提供了 `_resample_pcm_delta`，避免了由于采样率不匹配导致的爆音或语速异常。
2. **异步工具调用**：在实时语音场景中，工具调用（Acting）应在后台任务中执行，不应阻塞音频流。
3. **实时中断处理**：当检测到 `ClientResponseCancelEvent` 时，应立即调用 `model.disconnect()` 或发送取消信号给 API。

---

## 代码示例

### 启动一个实时语音服务器

```python
from agentscope.agent import RealtimeAgent
from agentscope.realtime import DashScopeRealtimeModel
import asyncio

# 1. 配置模型
model = DashScopeRealtimeModel(
    model_name="qwen3-omni-flash-realtime",
    api_key="YOUR_API_KEY",
    voice="Dylan" # 设置音色
)

# 2. 创建智能体
agent = RealtimeAgent(
    name="Friday",
    sys_prompt="You are a helpful assistant.",
    model=model
)

# 3. 启动
queue = asyncio.Queue()
await agent.start(queue)
```

---

## 相关文档

- AgentScope 架构设计 - AgentScope 的通用架构
- [实时流式处理对比](streaming-comparison.md) - 各种框架流式处理的异同

---

## 参考

- [AgentScope Realtime Tutorial](https://doc.agentscope.io/tutorial/task_realtime.html)
- [DashScope Realtime API 文档](https://help.aliyun.com/zh/dashscope/developer-reference/real-time-voice-interaction)

---

*创建时间：2026-03-02*
*更新时间：2026-03-02*
