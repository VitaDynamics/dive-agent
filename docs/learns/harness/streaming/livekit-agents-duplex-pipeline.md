---
tags: streaming, realtime, duplex, asr, tts, vad, livekit-agents, pipeline, voice-agent, webrtc, architecture
---

# LiveKit Agents 双工流式管道架构

> **范围**：LiveKit Agents 的 ASR→LLM→TTS 级联管道设计、双工流式实现、关键架构亮点（低延迟、中断处理、动态端点检测）以及面向 Agent 开发者的基础 API
>
> **综合自**：livekit/agents（`sources/agent-harness/livekit-agents/`）
>
> **优先级**：P0

---

## 概述

LiveKit Agents 是一个专为**实时语音/视频 AI Agent** 构建的框架，本质上是一条**级联管道**：

```
用户音频 → [VAD] → [ASR/STT] → [LLM] → [TTS] → 代理音频
```

其核心贡献不在于"做了什么"，而在于"怎么做得好"——通过异步流式生成器链、事件驱动的轮次检测和多层优化，将端到端延迟压到人类可接受的 <500ms 以内，同时支持打断和双工通信。

与其他 Agent 框架（如 AgentScope、pydantic-ai）最大的区别在于：**它是媒体流优先**。其抽象单位不是"消息"，而是"音频帧"；不是"请求-响应"，而是"持续双工流"。

---

## 问题描述

实时语音 Agent 面临三大核心挑战：

1. **延迟**：用户说完一句话，到听到 Agent 回复，整条链路（STT+LLM+TTS）的延迟需要 <1s，理想 <500ms
2. **打断（Barge-in）**：用户在 Agent 说话途中可以打断，Agent 应立即停止并重新响应
3. **轮次检测**：判断用户"说完了"还是"还在想"，过早认为结束会打断用户，过晚又增加延迟

LiveKit Agents 为每个问题都提供了精心设计的解法。

---

## 核心概念

### 1. 全异步流管道：三节点架构

整条管道由三个类型化的节点组成，每个节点都是**异步生成器**：

```python
# voice/io.py - 管道节点类型定义

STTNode = Callable[
    [AsyncIterable[rtc.AudioFrame], ModelSettings],
    AsyncIterable[stt.SpeechEvent | str]
]

LLMNode = Callable[
    [ChatContext, list[llm.Tool], ModelSettings],
    AsyncIterable[llm.ChatChunk | str | FlushSentinel]  # FlushSentinel 用于分段
]

TTSNode = Callable[
    [AsyncIterable[str], ModelSettings],
    AsyncIterable[rtc.AudioFrame]
]
```

**设计理由**：
- 三段都是 `AsyncIterable`，天然支持背压（backpressure）
- `FlushSentinel` 是分段边界信号，允许 TTS 在 LLM 还在生成时就开始合成第一句话
- 节点可以替换为任何实现，框架不绑定具体提供商

**数据流图（详细）**：

```
[用户麦克风]
      ↓ AudioFrame (16kHz, PCM)
[RoomIO._ParticipantAudioInputStream]
      ↓ 广播给 VAD 和 STT
  ┌───┴───────────────────────────┐
  ↓                               ↓
[VAD Stream]                 [STT Stream]
  ↓ VADEvent                     ↓ SpeechEvent
  │  .START_OF_SPEECH             │  .INTERIM_TRANSCRIPT
  │  .END_OF_SPEECH               │  .PREFLIGHT_TRANSCRIPT ← 抢占触发
  │  .INFERENCE_DONE              │  .FINAL_TRANSCRIPT
  └──────────────┬────────────────┘
                 ↓
        [AudioRecognition]（融合 VAD + STT）
                 ↓ RecognitionHooks 回调
        [AgentActivity]（轮次调度核心）
                 ↓ on_end_of_turn 触发
        [perform_llm_inference]
                 ↓ Chan[str | FlushSentinel]
        [perform_tts_inference + StreamPacer]
                 ↓ Chan[rtc.AudioFrame]
        [RoomIO._ParticipantAudioOutput]
                 ↓
        [WebRTC → 用户耳机]
```

---

### 2. VAD（语音活动检测）：流的起点

VAD 是管道的第一个门卫，决定哪些音频帧值得送给 STT：

```python
# vad.py

@dataclass
class VADEvent:
    type: VADEventType       # START_OF_SPEECH / END_OF_SPEECH / INFERENCE_DONE
    timestamp: float
    speech_duration: float   # 当前讲话持续时长（秒）
    silence_duration: float  # 当前静默持续时长（秒）
    frames: list[rtc.AudioFrame]  # 对应的音频帧
    probability: float       # 讲话概率（仅 INFERENCE_DONE 时有值）

class VADStream(ABC):
    def push_frame(self, frame: rtc.AudioFrame) -> None: ...
    def flush(self) -> None: ...
    async def __aiter__(self) -> AsyncIterator[VADEvent]: ...
```

**关键点**：VAD 事件中携带了对应的 `frames`，这意味着打断检测可以在帧级别精确判断，而不需要等 STT 结果。

---

### 3. STT（语音识别）：五种事件类型的精细设计

STT 的事件类型设计是理解低延迟的关键：

```python
# stt/stt.py

class SpeechEventType(str, Enum):
    START_OF_SPEECH = "start_of_speech"
    INTERIM_TRANSCRIPT = "interim_transcript"     # 中间结果（不稳定，但快）
    PREFLIGHT_TRANSCRIPT = "preflight_transcript" # ★ 预检结果（有把握但未最终确认）
    FINAL_TRANSCRIPT = "final_transcript"         # 最终确认结果
    END_OF_SPEECH = "end_of_speech"

@dataclass
class SpeechData:
    text: str
    confidence: float          # 置信度 [0, 1]
    words: list[TimedString] | None  # 字级时间戳（支持唇形同步）
```

**PREFLIGHT_TRANSCRIPT 的意义**：这是 LiveKit 的核心低延迟优化。在用户还在说话时，如果 STT 对前半段有足够置信度，它会发出 `PREFLIGHT_TRANSCRIPT`——此时 AgentActivity 可以**提前启动 LLM 推理**（抢占生成），等用户说完时 LLM 可能已经生成了一半文本。

---

### 4. 轮次检测：四种模式

检测"用户说完了"是最难的问题，LiveKit 提供了四种策略：

```python
# voice/turn.py

TurnDetectionMode = Literal["stt", "vad", "realtime_llm", "manual"] | _TurnDetector
```

| 模式 | 原理 | 适用场景 | 延迟 |
|------|------|----------|------|
| `"vad"` | 静默时长超阈值即认为结束 | 通用场景 | 中（取决于静默阈值） |
| `"stt"` | 等 FINAL_TRANSCRIPT 再判断 | 低噪环境 | 较高 |
| `"realtime_llm"` | 服务端检测（如 OpenAI Realtime API） | 需要 Realtime 模型 | 最低 |
| `"manual"` | 程序调用 `commit_user_turn()` | 特定交互流 | 完全可控 |
| 自定义 `_TurnDetector` | 基于 ML 预测的 EOU（End-of-Utterance） | 高精度需求 | 可调 |

#### 动态端点检测（DynamicEndpointing）

`endpointing.py` 中的 `DynamicEndpointing` 用**指数移动平均（EMA）**自适应调整等待时长：

```python
# endpointing.py

class DynamicEndpointing(BaseEndpointing):
    """
    根据历史对话动态调整 min_delay / max_delay

    场景 A：句子间暂停 → min_delay 应能包住这段暂停（不要误判 EOT）
    场景 B：用户停止后代理开始说话 → max_delay 内无新语音即触发
    """

    def __init__(self, min_delay: float, max_delay: float, alpha: float = 0.9):
        self._utterance_pause = ExpFilter(alpha=alpha, initial=min_delay,
                                          min_val=min_delay, max_val=max_delay)
        self._turn_pause = ExpFilter(alpha=alpha, initial=max_delay,
                                     min_val=min_delay, max_val=max_delay)
```

---

### 5. 打断处理（Barge-in）：分层设计

打断是双工体验的核心，LiveKit 有三层防护：

#### 层 1：SpeechHandle 的可中断标志

```python
# voice/speech_handle.py

class SpeechHandle:
    SPEECH_PRIORITY_LOW = 0
    SPEECH_PRIORITY_NORMAL = 5
    SPEECH_PRIORITY_HIGH = 10

    def __init__(self, *, allow_interruptions: bool, ...):
        self._allow_interruptions = allow_interruptions
        self._interrupt_fut = asyncio.Future[None]()  # 中断信号

    @property
    def interrupted(self) -> bool:
        return self._interrupt_fut.done()

    def interrupt(self, *, force: bool = False) -> SpeechHandle:
        """代理或用户触发中断"""
        if not force and not self._allow_interruptions:
            raise RuntimeError("This speech handle does not allow interruptions")
        if not self._interrupt_fut.done():
            self._interrupt_fut.set_result(None)
        return self
```

#### 层 2：假中断（False Interruption）恢复

用户偶尔发出短暂声音（咳嗽、呼吸声）可能触发误打断。LiveKit 的解法：

```python
# voice/turn.py

class InterruptionOptions(TypedDict, total=False):
    min_duration: float           # 最短打断时长（秒，默认 0.5）
    min_words: int                # 最少字数（STT 模式）
    resume_false_interruption: bool  # 假中断后恢复代理讲话
    false_interruption_timeout: float  # 假中断超时（秒，默认 2.0）
```

流程：
1. 用户开始说话 → 代理暂停（存入 `_paused_speech`）
2. 在 `false_interruption_timeout` 内用户无实质性输出
3. 代理从断点继续播放 `_paused_speech`

#### 层 3：自适应中断检测器

```python
# inference.py（内推理服务）

class AdaptiveInterruptionDetector:
    """
    基于 ML 的重叠讲话检测
    模式：
    - "adaptive"：ML 模型判断是否真的在讲话
    - "vad"：仅依赖 VAD 概率
    """
```

---

### 6. 抢占生成（Preemptive Generation）：低延迟的秘密武器

```python
# voice/agent_activity.py

@dataclass
class _PreemptiveGeneration:
    """
    在用户讲话完成前提前启动 LLM 推理

    触发条件：
    1. STT 返回 PREFLIGHT_TRANSCRIPT（置信度足够）
    2. 或 INTERIM_TRANSCRIPT 积累到足够长度

    优势：将 LLM TTFT（首字时间）从用户停止说话后移到说话期间
    风险：用户可能修改意图 → 需要撤销和重试机制
    """
    speech_handle: SpeechHandle
    user_message: llm.ChatMessage
    chat_ctx: llm.ChatContext
    created_at: float
```

时序对比：

```
无抢占：[用户说话....结束] → [LLM推理....] → [TTS合成....] → 播放
                            ↑ 全部延迟在这  ↑

有抢占：[用户说话..PREFLIGHT..结束]
                      ↑ [LLM推理.........]
                                    ↑ [TTS合成...]
                                              ↑ 用户停止 → 立即播放
```

---

### 7. TTS 流量控制（StreamPacer）：消除尖峰延迟

TTS 管道有一个反直觉的问题：**发文字太快也会有问题**。如果一次把整个 LLM 输出塞给 TTS，TTS 服务会产生大量缓冲，导致最后几句话的延迟飙升。

`stream_pacer.py` 的解法是"看着音频播放进度来决定何时发下一批文字"：

```python
# tts/stream_pacer.py

class SentenceStreamPacer:
    """
    批处理逻辑：
    1. 第一句话立即发送（最小化 TTFS - Time to First Sound）
    2. 之后监视已播放音频量：当剩余缓冲 <= min_remaining_audio 且生成暂停时发下一批
    3. 或文本积累到 max_text_length 时强制发送（避免长句等待）

    效果：保持 TTS 服务始终有 min_remaining_audio 秒的音频可播放，
         既不饿死也不撑死
    """

    def __init__(self, *, min_remaining_audio: float = 5.0, max_text_length: int = 300):
        ...
```

---

### 8. AgentSession & AgentActivity：胶合层

`AgentSession` 是用户直接使用的入口，`AgentActivity` 是内部的调度引擎：

```python
# voice/agent_session.py

class AgentSession(rtc.EventEmitter[EventTypes]):
    """
    将 STT/VAD/LLM/TTS 胶合成完整语音 Agent 的容器

    核心方法：
    - start()：启动 Agent 到 WebRTC 房间
    - generate_reply()：触发 LLM 生成
    - interrupt()：立即中断当前讲话
    - say()：直接 TTS 播放文本（不经过 LLM）
    """

    def __init__(
        self,
        stt: NotGivenOr[stt.STT | STTModels | str] = NOT_GIVEN,
        vad: NotGivenOr[vad.VAD] = NOT_GIVEN,
        llm: NotGivenOr[llm.LLM | llm.RealtimeModel | LLMModels | str] = NOT_GIVEN,
        tts: NotGivenOr[tts.TTS | TTSModels | str] = NOT_GIVEN,
        turn_handling: NotGivenOr[TurnHandlingOptions] = NOT_GIVEN,
    ) -> None: ...

    async def start(
        self,
        agent: Agent,
        *,
        room: rtc.Room,
        participant: rtc.RemoteParticipant | str | None = None,
    ) -> None: ...
```

`AgentActivity` 通过 `RecognitionHooks` 协议监听所有 STT/VAD 事件：

```python
# voice/agent_activity.py

class RecognitionHooks(Protocol):
    def on_start_of_speech(self, ev: vad.VADEvent | None) -> None: ...
    def on_vad_inference_done(self, ev: vad.VADEvent) -> None: ...
    def on_end_of_speech(self, ev: vad.VADEvent | None) -> None: ...
    def on_interim_transcript(self, ev: stt.SpeechEvent, *, speaking: bool | None) -> None: ...
    def on_final_transcript(self, ev: stt.SpeechEvent, *, speaking: bool | None = None) -> None: ...
    def on_end_of_turn(self, info: _EndOfTurnInfo) -> bool: ...  # 返回是否跳过本轮回复
    def on_preemptive_generation(self, info: _PreemptiveGenerationInfo) -> None: ...
    def on_interruption(self, ev: inference.OverlappingSpeechEvent) -> None: ...
```

---

### 9. 面向 Agent 开发者的基础 API

#### 定义一个语音 Agent

```python
from livekit.agents import Agent, AgentSession, JobContext
from livekit.agents.llm import function_tool
from livekit.plugins import silero

class MyVoiceAgent(Agent):
    def __init__(self):
        super().__init__(
            instructions="你是一个友好的语音助手，帮助用户解决问题。",
            # 可以在 Agent 级别覆盖 Session 级别的组件
            # stt=..., tts=..., llm=...
        )

    async def on_enter(self):
        """Agent 进入房间时主动打招呼"""
        await self.session.say("你好，我是语音助手，请问有什么可以帮助你？")

    @function_tool
    async def query_weather(self, city: str) -> str:
        """工具调用：查询天气（通过 docstring 自动生成 LLM tool schema）"""
        return f"{city}今天晴，25°C"

    async def on_user_turn_completed(self, turn_ctx, new_message):
        """每次用户说完话的钩子（可以注入上下文）"""
        # 可以在这里修改 ChatContext
        pass
```

#### 启动会话

```python
from livekit.agents import inference, cli
from livekit.agents.voice import AgentServer

server = AgentServer()

@server.rtc_session()
async def entrypoint(ctx: JobContext):
    session = AgentSession(
        vad=silero.VAD.load(),
        llm=inference.LLM("openai/gpt-4.1-mini"),   # 字符串自动解析提供商
        stt=inference.STT("deepgram/nova-3"),
        tts=inference.TTS("cartesia/sonic-3"),
        turn_handling=TurnHandlingOptions(
            turn_detection="vad",
            interruption=InterruptionOptions(
                enabled=True,
                mode="adaptive",        # ML 驱动的打断检测
                min_duration=0.5,
                resume_false_interruption=True,
            )
        )
    )

    await session.start(agent=MyVoiceAgent(), room=ctx.room)
    await ctx.connect()

if __name__ == "__main__":
    cli.run_app(server)
```

---

## 比较矩阵

| 特性 | LiveKit Agents | AgentScope（语音模式） | pydantic-ai |
|------|---------------|----------------------|-------------|
| 媒体传输 | WebRTC（低延迟，NAT穿透） | WebSocket | HTTP/SSE |
| STT 集成 | 原生一等公民（50+插件） | 插件（需手动集成） | 无内置 |
| VAD | 内置（Silero、WebRTC VAD） | 无 | 无 |
| 打断支持 | 自适应 ML 检测 + 假中断恢复 | 基础 | 无 |
| 轮次检测 | 4 种模式 + 自定义 | 静默检测 | N/A |
| 抢占生成 | ✅ PREFLIGHT 触发 | 无 | 无 |
| 流量控制 | StreamPacer（监视播放进度） | 无 | 无 |
| 工具调用 | 流式 + 多步 + MCP | 基础 | ✅ 流式 |
| 部署模式 | Worker Pool（进程级隔离） | 分布式 | 库 |

---

## 架构设计亮点汇总

| 亮点 | 实现机制 | 解决的问题 |
|------|----------|------------|
| **三段全异步流** | STTNode/LLMNode/TTSNode 均为 AsyncIterable | 端到端零阻塞，支持背压 |
| **PREFLIGHT 抢占** | STT PREFLIGHT_TRANSCRIPT → 提前启动 LLM | TTFB（首字节时间）最小化 |
| **FlushSentinel 分段** | LLM 输出插入 FlushSentinel | TTS 在 LLM 生成中途就开始合成 |
| **动态端点检测** | EMA 自适应调整 min/max delay | 避免误判 EOT，降低等待延迟 |
| **假中断恢复** | paused_speech + false_interruption_timeout | 咳嗽/噪音不触发真打断 |
| **StreamPacer** | 监视音频播放进度批量发文字 | 消除 TTS 尾部延迟尖峰 |
| **字级时间戳** | SpeechData.words（TimedString） | 支持唇形同步、精确字幕 |
| **自适应打断检测** | AdaptiveInterruptionDetector（ML） | 精确区分讲话和环境噪音 |

---

## 最佳实践

1. **首选 `"adaptive"` 打断模式**：VAD 模式容易被背景噪音误触，ML 模式能更好区分"真正在讲话"和"环境噪音"

2. **务必设置 `false_interruption_timeout`**：默认 2.0 秒，可以根据对话类型调整；流畅闲聊可以设短（0.5s），严肃问答应设长（3s+）

3. **利用 `on_enter` 主动打招呼**：不要让用户先说话，Agent 主动开口是更好的体验

4. **工具 docstring 即 schema**：`@function_tool` 自动从函数签名和 docstring 生成 LLM 工具描述，保持文档即代码

5. **反模式：不要在 `on_user_turn_completed` 中做长时间操作**：这会阻塞轮次检测，应该改为异步任务

6. **根据使用场景选择 TTS 提供商**：Cartesia Sonic 延迟低（适合闲聊），ElevenLabs 音质好（适合内容生成），Deepgram Aura 综合平衡

---

## 代码示例

### 带工具调用的完整语音 Agent

```python
from livekit.agents import Agent, AgentSession, JobContext, RunContext
from livekit.agents.llm import function_tool
from livekit.agents.voice import AgentServer, TurnHandlingOptions, InterruptionOptions
from livekit.plugins import silero
from livekit import agents

class CustomerServiceAgent(Agent):
    def __init__(self):
        super().__init__(
            instructions="""你是一个客服助手。
            说话简洁，每次回应不超过 2 句话。
            在注册完成后主动告知用户。
            """,
        )

    async def on_enter(self) -> None:
        # 主动打招呼
        self.session.generate_reply(
            instructions="简短介绍自己，问用户需要什么帮助"
        )

    @function_tool
    async def register_user(
        self,
        ctx: RunContext,
        name: str,
        email: str
    ) -> str:
        """注册用户到系统中。需要用户的姓名和邮箱。"""
        # 模拟注册
        return f"已成功注册用户 {name}，确认邮件发送到 {email}"

    @function_tool
    async def check_order_status(self, ctx: RunContext, order_id: str) -> str:
        """查询订单状态"""
        return f"订单 {order_id} 正在配送中，预计明天到达"


server = AgentServer()

@server.rtc_session()
async def entrypoint(ctx: JobContext):
    session = AgentSession(
        vad=silero.VAD.load(),
        llm=agents.inference.LLM("openai/gpt-4.1"),
        stt=agents.inference.STT("deepgram/nova-3"),
        tts=agents.inference.TTS("cartesia/sonic-3"),
        turn_handling=TurnHandlingOptions(
            turn_detection="vad",
            interruption=InterruptionOptions(
                enabled=True,
                mode="adaptive",
                min_duration=0.5,
                resume_false_interruption=True,
                false_interruption_timeout=2.0,
            ),
        )
    )

    await session.start(agent=CustomerServiceAgent(), room=ctx.room)
    await ctx.connect()
```

### 使用 RealtimeModel（最低延迟方案）

```python
from livekit.plugins import openai

# 直接使用 OpenAI Realtime API（服务端做 STT+LLM，省去本地 STT 延迟）
session = AgentSession(
    llm=openai.realtime.RealtimeModel(
        voice="echo",
        turn_detection=openai.realtime.ServerVAD(
            threshold=0.5,
            silence_duration_ms=200,
        )
    )
    # 注意：RealtimeModel 模式不需要独立的 STT/VAD/TTS
)
```

---

## 相关文档

- [AgentScope 实时语音](./realtime-voice-agentscope.md) - 对比多智能体平台的语音方案
- [异步流式一等公民](./async-streaming-first-class.md) - Python 异步流抽象模式
- [流式工具组装](./streaming-tool-assembly.md) - 流式过程中的工具调用组装

---

## 参考

- [LiveKit Agents 源码](https://github.com/livekit/agents)
- 核心文件：
  - `voice/io.py`：管道类型定义（STTNode/LLMNode/TTSNode）
  - `voice/agent_activity.py`：核心调度引擎（135KB）
  - `voice/agent_session.py`：AgentSession 容器（62KB）
  - `voice/audio_recognition.py`：ASR 流程管理
  - `voice/generation.py`：LLM→TTS 生成管道
  - `tts/stream_pacer.py`：TTS 流量控制
  - `voice/turn.py`：轮次检测配置
  - `voice/endpointing.py`：动态端点检测

---

*创建时间：2026-03-20*
*更新时间：2026-03-20*
