---
tags: streaming, realtime, kosong, agentscope, kimi-cli, comparison, architecture
---

# 实时语音 (AgentScope) vs. 增量流式 (Kosong) 设计对比

> **范围**：本文档对比分析了 AgentScope 的 Realtime 模块与 Kimi-CLI 的 Kosong 框架在处理“实时性”上的不同哲学、架构实现及设计亮点。
>
> **综合自**：AgentScope, Kimi-CLI (Kosong)
>
> **优先级**：P0

---

## 概述

在 AI Agent 领域，“实时性”有两种截然不同的解读：
1. **感官实时 (Perceptual Real-time)**：侧重于毫秒级的音视频反馈，强调全双工、低延迟和物理世界的同步感。
2. **逻辑流式 (Logical Streaming)**：侧重于逻辑生成的连续性与状态的一致性，强调在长文本或工具调用过程中 UI 与后台状态的平滑同步。

本文通过对比 AgentScope (Realtime) 和 Kosong (Streaming)，揭示这两种路径在 LLM 抽象层设计上的差异。

---

## 核心架构对比

### 1. AgentScope: 事件驱动的 WebSocket 架构

AgentScope 的 Realtime 模块是为**音视频原生交互**设计的。

*   **设计哲学**：将交互视为一系列离散的“事件”。
*   **核心抽象**：
    *   `RealtimeModelBase`: 抽象了 WebSocket 连接管理。
    *   `ServerEvents/ClientEvents`: 统一定义了音频增量 (`AudioDelta`)、语音开始/结束检测 (`VAD`)、实时中断 (`Cancel`)。
*   **设计亮点：语音聊天室 (ChatRoom)**
    *   通过 `ChatRoom` 管道实现多智能体广播逻辑。
    *   内置 `_resample_pcm_delta` 重采样工具，解决不同模型协议间的采样率不兼容痛点。

```python
# AgentScope 的异步双循环模式
async def start(self, outgoing_queue: Queue):
    # 循环 A: 处理来自模型的消息并推送给前端/其它 Agent
    self._model_response_handling_task = asyncio.create_task(self._model_response_loop(outgoing_queue))
    # 循环 B: 监听外部输入并推送给模型
    self._external_event_handling_task = asyncio.create_task(self._forward_loop())
```

### 2. Kosong: 增量合并的消息模型

Kosong 是为**高质量开发工具 (CLI/IDE)** 的文本和工具流设计的。

*   **设计哲学**：将流式输出视为“正在增长的消息部件”。
*   **核心抽象**：
    *   `MergeableMixin`: 定义了 `merge_in_place` 接口，允许不同类型的 `ContentPart` 原地合并。
    *   `StreamedMessagePart`: 联合类型，涵盖 `TextPart`、`ThinkPart`、`ToolCallPart`。
*   **设计亮点：原地合并逻辑 (In-place Merging)**
    *   通过递归合并增量片段（如 `TextPart` 拼接字符串，`ToolCallPart` 拼接 JSON 参数），确保在生成过程中 Agent 内部状态始终是一个完整的、可验证的消息对象。

```python
# Kosong 的增量合并逻辑
async def generate(...):
    async for part in stream:
        if pending_part is None:
            pending_part = part
        elif not pending_part.merge_in_place(part): 
            # 如果无法合并（如从文本转为工具调用），则提交当前部分并开启新部分
            _message_append(message, pending_part)
            pending_part = part
```

---

## 详细差异对比

| 维度 | AgentScope (Realtime) | Kimi-CLI (Kosong) |
| :--- | :--- | :--- |
| **底层协议** | 主要是 WebSocket (OpenAI Realtime/DashScope API) | 主要是 SSE (Server-Sent Events) 或 Chunked HTTP |
| **数据单元** | **事件 (Event)**：如 `AudioDelta`, `SpeechStarted` | **部件 (Part)**：如 `TextPart`, `ToolCallPart` |
| **处理模式** | **双向并发流**：输入和输出在不同的异步任务中同时进行 | **单向增量流**：按序接收片段并进行状态更新 |
| **中断机制** | **原生中断**：发送 `cancel` 事件，API 立即停止并丢弃缓冲区 | **逻辑中断**：通常通过取消异步任务实现 |
| **多模态友好度** | **语音/视频原生**：支持二进制音频流重采样 | **文本/逻辑原生**：支持特殊的 `ThinkPart` (推理流) |
| **状态一致性** | 弱（关注实时的“听”和“说”） | 强（关注生成出的消息对象是否完整可复用） |

---

## 设计亮点总结

### AgentScope: 模态屏蔽层
AgentScope 的最大亮点是它成功地**屏蔽了厂商实时协议的巨大差异**。DashScope、OpenAI 和 Gemini 的 Realtime API 在握手、音频格式和事件命名上完全不同，AgentScope 通过统一的 `ServerEvents` 让开发者可以编写一套代码适配多个模型，这在实时语音领域是非常难得的。

### Kosong: 鲁棒的消息流模型
Kosong 的最大亮点是它的**容错性与可维护性**。传统的流式处理往往只是简单的字符串拼接，而在 Kosong 中，每个增量片段都是 Pydantic 模型。这种设计使得它在处理诸如“推理流 (Thinking)”与“回复流”切换、复杂工具调用参数拼接时，依然能保持类型安全和逻辑清晰。

---

## 相关文档

- [AgentScope 实时语音处理](../harness/streaming/realtime-voice-agentscope.md)
- [异步流式一等公民](../harness/streaming/async-streaming-first-class.md)
- [Kimi CLI 架构](../harness/architecture/kimi-cli-architecture.md)

---

*创建时间：2026-03-02*
*更新时间：2026-03-02*
